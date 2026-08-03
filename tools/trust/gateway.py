"""The single decision point for every authorization question.

Before v0.9.4 the platform had four trust systems. Each was reviewed, each was
fail-closed, and no one could answer "what does this platform trust?" without
reading four unrelated modules. This is the one place that question is now
answered.

Every migrated call site asks `query()`. None of them decides.

## Two sources, one authority

The gateway resolves a verdict from one of two places, and always records
which:

- **`trust-plane-runtime`** — when a trust store is configured, the Trust Plane
  decides. Root-terminated, immutable, auditable. Authoritative when present.
- **`code-owned-policy`** — otherwise, the migrated rules in `policy.py`
  decide. Reviewed code, fail-closed, but **not** traceable to an external
  Operator Root Authority.

Recording the source is the point. A decision made from reviewed code and one
made from a root-terminated chain are different things, and a verdict that
could not tell them apart would hide exactly the gap this release leaves open:
until an operator instantiates a root authority and seeds a store, the platform
enforces the same rules it always did, from the same reviewed code, in one
place instead of four.

The runtime is never *combined* with policy. When a store is configured it is
authoritative and policy is not consulted, because two sources that can both
answer are two authorities again.

## Deny by default

Every path returns a denial with written reasons unless something explicitly
permitted the request. There is no default-allow branch, no wildcard, and no
fallback that silently succeeds. An unrecognised domain, a missing subject, and
an unreadable store all fail closed.

Nothing here writes, allocates an identifier, or emits an audit event. Asking
what is trusted must not change what is trusted.

See docs/trust/trust-migration.md and docs/decisions/ADR-0011-trust-plane.md.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Mapping

from .policy import DOMAIN_FOR_MECHANISM, SUPPORTED_DOMAINS, evaluate_policy


class VerdictSource(str, Enum):
    """Which authority produced a verdict.

    Never inferred by a caller: the gateway states it, so a reader can tell a
    root-terminated decision from a code-owned one without guessing.
    """

    TRUST_PLANE_RUNTIME = "trust-plane-runtime"
    CODE_OWNED_POLICY = "code-owned-policy"


@dataclass(frozen=True)
class TrustVerdict:
    """The answer to one authorization question.

    Immutable, and carries its reasons rather than a bare boolean: a denial an
    operator cannot read is a denial they will route around.
    """

    allowed: bool
    domain: str
    subject_id: str
    action: str | None
    source: str
    reasons: tuple[str, ...] = ()
    effective_state: str | None = None
    evaluated_at: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "allowed": self.allowed,
            "domain": self.domain,
            "subject_id": self.subject_id,
            "action": self.action,
            "source": self.source,
            "reasons": list(self.reasons),
            "effective_state": self.effective_state,
            "evaluated_at": self.evaluated_at,
        }

    def require(self, error_type) -> None:
        """Raise `error_type` with the first reason when denied.

        Call sites use this so a migrated refusal keeps raising the same
        exception, with the same message, as it did before the migration.
        """
        if not self.allowed:
            raise error_type(self.reasons[0] if self.reasons
                             else f"{self.domain} decision denied")


class TrustGateway:
    """Resolves authorization questions against one authority at a time."""

    def __init__(self, store=None) -> None:
        # A store is optional and never created here. Constructing one as a
        # side effect of asking a question would make the act of querying
        # change the thing being queried.
        self.store = store

    def query(self, *, domain: str, subject_id: str, action: str | None = None,
              evaluated_at: datetime | None = None,
              context: Mapping[str, Any] | None = None) -> TrustVerdict:
        """Decide, and say which authority decided and why."""
        stamp = evaluated_at.isoformat() if evaluated_at is not None else None

        if domain not in SUPPORTED_DOMAINS:
            return TrustVerdict(
                allowed=False, domain=domain, subject_id=subject_id, action=action,
                source=VerdictSource.CODE_OWNED_POLICY.value,
                reasons=(f"domain '{domain}' is not one this release decides for; "
                         "an unrecognised domain fails closed",),
                evaluated_at=stamp)

        if self.store is not None:
            return self._from_runtime(domain, subject_id, action, evaluated_at,
                                      context, stamp)

        reasons = evaluate_policy(domain, subject_id, action, context)
        return TrustVerdict(
            allowed=not reasons, domain=domain, subject_id=subject_id,
            action=action, source=VerdictSource.CODE_OWNED_POLICY.value,
            reasons=tuple(reasons), evaluated_at=stamp)

    def _from_runtime(self, domain, subject_id, action, evaluated_at, context,
                      stamp) -> TrustVerdict:
        """Ask the Trust Plane. Any failure to read is a denial, never a pass."""
        from . import query as trust_query

        if evaluated_at is None:
            return TrustVerdict(
                allowed=False, domain=domain, subject_id=subject_id, action=action,
                source=VerdictSource.TRUST_PLANE_RUNTIME.value,
                reasons=("a store-backed decision requires an explicit evaluation "
                         "moment; time is never read from the clock here",),
                evaluated_at=stamp)

        try:
            result = trust_query.evaluate_subject(
                self.store, subject_id, evaluated_at=evaluated_at,
                operation=action, activity_kind="normal")
        except Exception as error:  # noqa: BLE001 - unreadable state is a denial
            return TrustVerdict(
                allowed=False, domain=domain, subject_id=subject_id, action=action,
                source=VerdictSource.TRUST_PLANE_RUNTIME.value,
                reasons=(f"the trust store could not be read ({type(error).__name__}); "
                         "unreadable state fails closed",),
                evaluated_at=stamp)

        return TrustVerdict(
            allowed=bool(result.get("allowed")), domain=domain,
            subject_id=subject_id, action=action,
            source=VerdictSource.TRUST_PLANE_RUNTIME.value,
            reasons=tuple(result.get("denied_reasons") or ()),
            effective_state=result.get("effective_state"), evaluated_at=stamp)


# The default gateway: no store configured, so code-owned policy decides. A
# caller with a store constructs its own rather than mutating this one, because
# a shared mutable authority is how a second authority appears.
_DEFAULT = TrustGateway()


def query(*, domain: str, subject_id: str, action: str | None = None,
          evaluated_at: datetime | None = None,
          context: Mapping[str, Any] | None = None,
          store=None) -> TrustVerdict:
    """Ask the trust gateway. The entry point every migrated call site uses."""
    gateway = TrustGateway(store=store) if store is not None else _DEFAULT
    return gateway.query(domain=domain, subject_id=subject_id, action=action,
                         evaluated_at=evaluated_at, context=context)


def domain_for(mechanism: str) -> str | None:
    """The ADR-0011 domain a migrated mechanism belongs to."""
    return DOMAIN_FOR_MECHANISM.get(mechanism)
