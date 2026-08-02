"""Deterministic expiry evaluation.

Expiry is the only state change time may cause, and it changes nothing on disk.
The stored state stays exactly as written; the effective state is computed at
an explicit evaluation moment.

No function here reads the wall clock. The caller supplies `evaluated_at`, so
an answer is reproducible rather than a race, and a test can assert the exact
boundary instead of approximating it.
"""

from __future__ import annotations

from datetime import datetime

from .models import TrustState, require_aware

# Only a usable state can age out. Expiry never rewrites a judgement someone
# made: a revoked subject stays revoked after its notional boundary passes.
EXPIRABLE = frozenset({TrustState.TRUSTED.value, TrustState.RESTRICTED.value})


def is_expired(expiration: datetime | None, evaluated_at: datetime) -> bool:
    """True when the evaluation moment is at or after the boundary."""
    if expiration is None:
        return False
    require_aware(expiration, "expiration")
    require_aware(evaluated_at, "evaluated_at")
    return evaluated_at >= expiration


def effective_state(stored_state: str, expiration: datetime | None,
                    evaluated_at: datetime) -> str:
    """The state as of an explicit moment, without touching the record.

    A grant with no expiration never expires; that is a decision someone made,
    not an oversight to correct here.
    """
    require_aware(evaluated_at, "evaluated_at")
    if stored_state not in EXPIRABLE:
        return stored_state
    if is_expired(expiration, evaluated_at):
        return TrustState.EXPIRED.value
    return stored_state
