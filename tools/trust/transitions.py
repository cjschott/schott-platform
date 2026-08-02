"""The state-transition engine.

The transition table is code-owned and explicit. Every permitted change is
written out here, in reviewed code, so "can this become trusted?" is answered
by reading a table rather than by tracing conditionals.

Two rules govern the whole table:

- **Only Expired may occur automatically**, through the passage of time from a
  usable state. Every other change requires a decision.
- **No automatic transition may produce a usable or judgemental state.** Nothing
  becomes trusted, restricted, quarantined, revoked, or rejected because time
  passed or a condition cleared.

Revoked and Rejected are terminal within their lineage: later approval requires
a new lineage. Expired is not terminal — a renewal decision advances the same
lineage, because the grant aged out rather than going wrong, and forcing a new
lineage would fragment a periodically-renewed subject's history into one chain
per renewal.

See docs/decisions/ADR-0011-trust-plane.md.
"""

from __future__ import annotations

from dataclasses import dataclass

from .models import TrustState

U = TrustState.UNKNOWN.value
P = TrustState.PENDING.value
T = TrustState.TRUSTED.value
R = TrustState.RESTRICTED.value
Q = TrustState.QUARANTINED.value
V = TrustState.REVOKED.value
E = TrustState.EXPIRED.value
J = TrustState.REJECTED.value

# States a subject may actually be used in. Everything else fails closed.
USABLE = frozenset({T, R})

# Terminal within a lineage. Later approval requires a new lineage.
TERMINAL = frozenset({V, J})

# (previous, requested) -> the rule that permits it. Decisions only.
BY_DECISION: dict[tuple[str, str], str] = {
    (U, P): "an unknown subject may be submitted for review",
    (U, T): "an unknown subject may be approved outright by an authority",
    (U, R): "an unknown subject may be approved with a bounded scope",
    (U, Q): "an unknown subject may be quarantined pending investigation",
    (U, J): "an unknown subject's request may be considered and refused",

    (P, T): "a pending request may be approved",
    (P, R): "a pending request may be approved with a bounded scope",
    (P, Q): "a pending subject may be quarantined pending investigation",
    (P, J): "a pending request may be considered and refused",

    (T, R): "an authority may narrow a grant to a bounded scope",
    (T, Q): "a trusted subject may be quarantined when it becomes suspect",
    (T, V): "an authority may withdraw a granted trust",

    (R, T): "an authority may broaden a restricted grant by a new decision",
    (R, Q): "a restricted subject may be quarantined when it becomes suspect",
    (R, V): "an authority may withdraw a restricted grant",

    (Q, T): "an investigation may conclude and restore trust by decision",
    (Q, R): "an investigation may conclude and restore a bounded grant",
    (Q, V): "an investigation may conclude in withdrawal",
    (Q, J): "an investigation may conclude that trust was never warranted",

    # Expiry continues the lineage: renewal is a decision on the same chain.
    (E, T): "an expired grant may be renewed by a new decision",
    (E, R): "an expired grant may be renewed with a bounded scope",
}

# The only transition time may cause, and only from a usable state.
BY_TIME: dict[tuple[str, str], str] = {
    (T, E): "a grant elapsed past its recorded expiration",
    (R, E): "a bounded grant elapsed past its recorded expiration",
}


@dataclass(frozen=True)
class TransitionOutcome:
    """Why a transition was permitted or refused.

    Every field exists so a denial can be read without consulting the table:
    an operator seeing "denied" during an incident needs the governing rule and
    what to do instead, not a boolean.
    """

    previous_state: str
    requested_state: str
    allowed: bool
    governing_rule: str
    decision_required: bool
    new_lineage_required: bool
    resulting_usable: bool

    def to_dict(self) -> dict[str, object]:
        return {
            "previous_state": self.previous_state,
            "requested_state": self.requested_state,
            "allowed": self.allowed,
            "governing_rule": self.governing_rule,
            "decision_required": self.decision_required,
            "new_lineage_required": self.new_lineage_required,
            "resulting_usable": self.resulting_usable,
        }


def is_usable(state: str) -> bool:
    """Whether a subject in this state may be used at all."""
    return state in USABLE


def is_terminal(state: str) -> bool:
    """Whether this state ends its lineage."""
    return state in TERMINAL


def evaluate_transition(previous_state: str, requested_state: str, *,
                        by_decision: bool) -> TransitionOutcome:
    """Decide whether a state change is permitted, and say why.

    `by_decision=False` means "could time alone do this?", and the answer is
    yes for exactly one pair of transitions.
    """
    known = {s.value for s in TrustState}
    if previous_state not in known or requested_state not in known:
        return TransitionOutcome(
            previous_state=previous_state, requested_state=requested_state,
            allowed=False,
            governing_rule="unrecognised state; unknown input fails closed",
            decision_required=True, new_lineage_required=False,
            resulting_usable=False)

    if not by_decision:
        rule = BY_TIME.get((previous_state, requested_state))
        if rule:
            return TransitionOutcome(
                previous_state=previous_state, requested_state=requested_state,
                allowed=True, governing_rule=rule,
                decision_required=False, new_lineage_required=False,
                resulting_usable=is_usable(requested_state))
        return TransitionOutcome(
            previous_state=previous_state, requested_state=requested_state,
            allowed=False,
            governing_rule=(
                "only expiration may occur automatically; every other state "
                "change requires an explicit decision"),
            decision_required=True,
            new_lineage_required=previous_state in TERMINAL,
            resulting_usable=False)

    if previous_state in TERMINAL:
        return TransitionOutcome(
            previous_state=previous_state, requested_state=requested_state,
            allowed=False,
            governing_rule=(
                f"'{previous_state}' is terminal within its lineage; later approval "
                "requires a new lineage referencing this history"),
            decision_required=True, new_lineage_required=True,
            resulting_usable=False)

    rule = BY_DECISION.get((previous_state, requested_state))
    if rule:
        return TransitionOutcome(
            previous_state=previous_state, requested_state=requested_state,
            allowed=True, governing_rule=rule,
            decision_required=True, new_lineage_required=False,
            resulting_usable=is_usable(requested_state))

    return TransitionOutcome(
        previous_state=previous_state, requested_state=requested_state,
        allowed=False,
        governing_rule=(
            f"no rule permits '{previous_state}' to become '{requested_state}'; "
            "the transition table is code-owned and this pair is absent"),
        decision_required=True, new_lineage_required=False,
        resulting_usable=False)
