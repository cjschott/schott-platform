"""Combine an integrity status with a behavioural status.

Operational Integrity answers "does this match the snapshot we confirmed was
good?". The Experience Engine answers "is this normal for this system?". They
are independent axes, and the interesting information is in the combination.

**EXPECTED is not equivalent to MATCH.** MATCH compares against a snapshot;
EXPECTED compares against operational history. A system can match a snapshot
while behaving unusually, and can differ from a snapshot while behaving exactly
as it always has.

| Integrity | Behaviour | Reading |
|---|---|---|
| MATCH | EXPECTED | Ideal — configuration and behaviour both as known |
| MATCH | UNEXPECTED | Configuration unchanged, behaviour is not; something changed underneath |
| DRIFT | EXPECTED | Configuration changed and behaviour is normal; intentional change is likely |
| DRIFT | UNEXPECTED | Both changed; the highest-priority combination |

This lives in the experience package rather than the integrity package on
purpose. Experience already depends on integrity's vocabulary; making integrity
depend on experience would create a cycle and would make the older, more
conservative layer depend on the newer one.

Nothing here acts. A priority is a suggestion about where a human should look.
"""

from __future__ import annotations

from typing import Any

from .models import BaselineStatus

# Priorities are advisory labels, not severities that trigger anything.
PRIORITY_NONE = "none"
PRIORITY_REVIEW = "review"
PRIORITY_INVESTIGATE = "investigate"
PRIORITY_HIGH = "high"

_DETERMINATE_BEHAVIOUR = {BaselineStatus.EXPECTED.value, BaselineStatus.UNEXPECTED.value}


def combined_assessment(*, integrity_status: str, behaviour_status: str,
                        integrity_report: str | None = None,
                        baseline: str | None = None) -> dict[str, Any]:
    """Return both axes, a priority, and an explanation.

    Deterministic: the same pair always produces the same result.
    """
    integrity = str(integrity_status)
    behaviour = str(behaviour_status)

    matches_snapshot = integrity == "MATCH"
    differs_from_snapshot = integrity in {"DRIFT", "PARTIAL"}
    behaviour_known = behaviour in _DETERMINATE_BEHAVIOUR
    behaviour_unexpected = behaviour == BaselineStatus.UNEXPECTED.value

    if not behaviour_known:
        # An unknown or thin history never escalates on its own. Escalating on
        # an absence of history would page someone for not having watched.
        priority = PRIORITY_REVIEW if differs_from_snapshot else PRIORITY_NONE
        explanation = (
            f"Integrity is {integrity} and behaviour is {behaviour}. Operational "
            "history cannot characterise this metric yet, so no behavioural "
            "conclusion is drawn; an absence of history is not abnormal behaviour."
        )
    elif matches_snapshot and not behaviour_unexpected:
        priority = PRIORITY_NONE
        explanation = (
            "Configuration matches the snapshot and behaviour is within its "
            "operational history. Nothing here suggests a problem."
        )
    elif matches_snapshot and behaviour_unexpected:
        priority = PRIORITY_INVESTIGATE
        explanation = (
            "Configuration still matches the snapshot, but behaviour differs from "
            "operational history. Something changed that configuration does not "
            "explain — load, a dependency, or the environment."
        )
    elif differs_from_snapshot and not behaviour_unexpected:
        priority = PRIORITY_REVIEW
        explanation = (
            "Configuration differs from the snapshot while behaviour remains within "
            "operational history. Intentional change is the likely explanation, and "
            "the snapshot may simply be out of date."
        )
    elif differs_from_snapshot and behaviour_unexpected:
        priority = PRIORITY_HIGH
        explanation = (
            "Configuration differs from the snapshot and behaviour differs from "
            "operational history. Both axes disagree with what is known, which is "
            "the combination most worth investigating first."
        )
    else:
        priority = PRIORITY_REVIEW if behaviour_unexpected else PRIORITY_NONE
        explanation = (
            f"Integrity is {integrity} and behaviour is {behaviour}. The integrity "
            "comparison reached no determinate answer, so the behavioural reading "
            "stands alone."
        )

    return {
        "integrity_status": integrity,
        "behaviour_status": behaviour,
        "priority": priority,
        "explanation": explanation,
        "integrity_report": integrity_report,
        "baseline": baseline,
        "interpretation": (
            "EXPECTED compares against operational history; MATCH compares against a "
            "snapshot. They are independent and neither implies the other."
        ),
        "action": "advisory only; nothing is executed",
    }
