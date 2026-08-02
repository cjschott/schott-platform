"""Scope and activity evaluation.

Deny by default, on every dimension. A request that does not name a capability,
an operation, a data classification, and a target is denied — not because the
scope forbade it, but because nothing permitted it. An unstated dimension is
the most common way a bounded grant quietly becomes an unbounded one.

State overrides scope, always. A quarantined, revoked, expired, rejected,
unknown, or pending subject is denied even when its recorded scope matches the
request perfectly, because the scope describes what a grant would permit and
the state describes whether there is a grant.

Nothing here produces a number. There is no score, no threshold, and no partial
allowance: the answer is allowed or denied, with written reasons.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from .models import TrustEvaluation, TrustScope, TrustState, require_aware
from .transitions import is_usable

# Activities a subject may be evaluated for. Deliberately small: a general
# "other" kind would become the way around this function.
ACTIVITY_KINDS = ("normal", "verification", "investigation")

# Operations a quarantined subject may still participate in. Code-owned, and
# each is an act of establishing what is true about the subject -- never an act
# of using it, and never a repair. There is no wildcard: a generic
# "investigation" with no named operation is refused, because that is how
# quarantine becomes a formality.
QUARANTINE_PERMITTED_OPERATIONS = frozenset({
    "trust.verify_identity",
    "trust.verify_fingerprint",
    "trust.collect_verification_evidence",
    "trust.review_history",
})


@dataclass(frozen=True)
class ScopeEvaluation:
    """Whether a bounded request is permitted, and every reason it was not."""

    allowed: bool
    denied_reasons: tuple[str, ...]
    matched_scope: str | None
    effective_state: str
    evaluated_at: datetime

    def to_dict(self) -> dict[str, object]:
        return {
            "allowed": self.allowed,
            "denied_reasons": list(self.denied_reasons),
            "matched_scope": self.matched_scope,
            "effective_state": self.effective_state,
            "evaluated_at": self.evaluated_at.isoformat(),
        }


@dataclass(frozen=True)
class ActivityEvaluation:
    """Whether a kind of activity is permitted in the current state."""

    allowed: bool
    denied_reasons: tuple[str, ...]
    activity_kind: str
    operation_id: str | None
    effective_state: str
    evaluated_at: datetime

    def to_dict(self) -> dict[str, object]:
        return {
            "allowed": self.allowed,
            "denied_reasons": list(self.denied_reasons),
            "activity_kind": self.activity_kind,
            "operation_id": self.operation_id,
            "effective_state": self.effective_state,
            "evaluated_at": self.evaluated_at.isoformat(),
        }


def _state_denial(state: str) -> str | None:
    """Why this state forbids use, or None when it permits it."""
    if is_usable(state):
        return None
    explanations = {
        TrustState.UNKNOWN.value:
            "no approved trust decision exists for this subject; unknown fails closed",
        TrustState.PENDING.value:
            "a decision is awaiting review; pending is operationally equivalent to unknown",
        TrustState.QUARANTINED.value:
            "the subject is quarantined; normal use is forbidden while identity or "
            "integrity is in question",
        TrustState.REVOKED.value:
            "trust was explicitly withdrawn; a revoked subject cannot be used and "
            "cannot be reactivated within its lineage",
        TrustState.EXPIRED.value:
            "the grant elapsed past its recorded expiration; renewal requires a new decision",
        TrustState.REJECTED.value:
            "trust was considered and denied; it was never granted",
    }
    return explanations.get(state, f"state '{state}' does not permit use")


def evaluate_scope(evaluation: TrustEvaluation, capability: str | None = None,
                   operation: str | None = None,
                   data_classification: str | None = None,
                   target: str | None = None, *,
                   evaluated_at: datetime) -> ScopeEvaluation:
    """Decide whether a bounded request falls inside a subject's grant."""
    require_aware(evaluated_at, "evaluated_at")
    state = evaluation.effective_state
    reasons: list[str] = []

    denial = _state_denial(state)
    if denial:
        # State overrides scope. Reported alone: listing scope mismatches too
        # would suggest a matching scope could have helped.
        return ScopeEvaluation(allowed=False, denied_reasons=(denial,),
                               matched_scope=None, effective_state=state,
                               evaluated_at=evaluated_at)

    scope = evaluation.scope
    if scope is None:
        return ScopeEvaluation(
            allowed=False,
            denied_reasons=("the subject carries no scope; a request with nothing "
                            "permitting it is denied",),
            matched_scope=None, effective_state=state, evaluated_at=evaluated_at)

    if scope.validity_start is not None and evaluated_at < scope.validity_start:
        reasons.append("the evaluation moment is before the scope's validity start")
    if scope.validity_end is not None and evaluated_at >= scope.validity_end:
        reasons.append("the evaluation moment is at or after the scope's validity end")

    for value, permitted, label in (
        (capability, scope.permitted_capabilities, "capability"),
        (operation, scope.permitted_operations, "operation"),
        (data_classification, scope.permitted_data_classifications, "data classification"),
        (target, scope.permitted_targets, "target"),
    ):
        if value is None:
            reasons.append(
                f"no {label} was supplied; every dimension must be named because "
                "scope is deny-by-default")
            continue
        if value not in permitted:
            reasons.append(f"{label} '{value}' is not within the approved scope")

    return ScopeEvaluation(allowed=not reasons, denied_reasons=tuple(reasons),
                           matched_scope=scope.scope_id if not reasons else None,
                           effective_state=state, evaluated_at=evaluated_at)


def evaluate_activity(trust_evaluation: TrustEvaluation, activity_kind: str,
                      operation_id: str | None = None, *,
                      evaluated_at: datetime) -> ActivityEvaluation:
    """Decide whether a kind of activity is permitted in the current state.

    Quarantine is the interesting case: normal use is forbidden, and the only
    activity permitted is the explicitly named work of establishing what is
    true about the subject.
    """
    require_aware(evaluated_at, "evaluated_at")
    state = trust_evaluation.effective_state
    reasons: list[str] = []

    if activity_kind not in ACTIVITY_KINDS:
        return ActivityEvaluation(
            allowed=False,
            denied_reasons=(f"activity kind '{activity_kind}' is not recognised; "
                            "unknown input fails closed",),
            activity_kind=activity_kind, operation_id=operation_id,
            effective_state=state, evaluated_at=evaluated_at)

    if state == TrustState.QUARANTINED.value:
        if activity_kind == "normal":
            reasons.append(
                "the subject is quarantined; normal capability use is forbidden")
        elif operation_id is None:
            reasons.append(
                f"a quarantined subject may perform {activity_kind} activity only "
                "through an explicitly named operation; there is no generic wildcard")
        elif operation_id not in QUARANTINE_PERMITTED_OPERATIONS:
            reasons.append(
                f"operation '{operation_id}' is not in the approved quarantine "
                "verification set")
        return ActivityEvaluation(allowed=not reasons, denied_reasons=tuple(reasons),
                                  activity_kind=activity_kind, operation_id=operation_id,
                                  effective_state=state, evaluated_at=evaluated_at)

    denial = _state_denial(state)
    if denial:
        reasons.append(denial)

    return ActivityEvaluation(allowed=not reasons, denied_reasons=tuple(reasons),
                              activity_kind=activity_kind, operation_id=operation_id,
                              effective_state=state, evaluated_at=evaluated_at)
