# Trust States

Eight states describe the standing of one subject in one domain.

> **Architecture only. Not yet implemented.** No runtime assigns or evaluates
> these states in this release. Reserved for **v0.9.2**.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md). See also
[the Trust Plane overview](trust-plane.md) and [trust domains](trust-domains.md).

## The states

| State | Meaning | Usable? | Reached by |
|---|---|---|---|
| **Unknown** | No record exists. The platform knows nothing about this subject. | No | Default for everything |
| **Pending** | A decision has been requested but not made. | No | Submission for review |
| **Trusted** | Approved for the recorded scope. | Yes, within scope | An approving decision |
| **Restricted** | Identity is trusted; authority is deliberately limited to an explicit non-empty scope. | **Yes, usable within that scope** | A decision granting less than asked |
| **Quarantined** | Identity, integrity, provenance, or behaviour is suspect. | **No — not usable for normal work** | A decision, never automatically |
| **Revoked** | Previously granted trust was explicitly withdrawn. | No | A revoking decision |
| **Expired** | Trust ceased solely because its approved time boundary elapsed. | No | Time, against a recorded expiration |
| **Rejected** | A proposed decision was considered and denied; trust was **never granted**. | No | A refusing decision |

## Unknown is the default, and it fails closed

The absence of a record is `Unknown`, never `Trusted`. A default of anything
else is trust on first use wearing a different name.

This is what v0.9.0's supervised validation demonstrated: the host had no
record, so the state was `Unknown`, so the collection stopped before any
connection was attempted.

## Pending is not provisional trust

`Pending` behaves exactly like `Unknown` — it is not usable. A state meaning
"not yet trusted but usable in the meantime" is trust on first use with a
waiting period, and it would be reached for during precisely the incidents that
make it dangerous.

## Restricted versus Quarantined

The distinction that is easiest to lose, and the most costly to lose during an
incident.

| | **Restricted** | **Quarantined** |
|---|---|---|
| What it says | Identity is trusted; authority is deliberately limited | Identity or integrity is **suspect** |
| Is it suspicion? | **No — restriction is not suspicion** | Yes |
| Usable? | **Yes, within its explicit scope** | **No — not usable for normal work** |
| Scope | **Required, non-empty** | Only approved verification or investigation |
| How it ends | New approval to broaden scope | New decision to exit quarantine |

**Restriction is not suspicion.** A `Restricted` record is a normal, expected
governance outcome: the subject was evaluated and granted less authority than it
asked for, on purpose. Nothing is wrong with it.

**Quarantine is not permanent revocation.** It is a withheld state pending an
answer. The subject may return to `Trusted` or `Restricted` — but only through a
new decision, never because the alert cleared.

Reporting either as the other destroys the difference between "we deliberately
gave it less" and "we are worried about it".

### Worked examples

**Restricted.** `MainPC` may execute local-only coding workloads but may not
receive data above its approved trust classification. Its identity is not in
doubt; its authority is bounded. It is used every day, within that scope.

**Quarantined.** `MainPC`'s host identity changed unexpectedly, so normal
placement is forbidden while identity verification is performed. Nothing runs
there until the question is answered by a decision.

## Rejected versus Revoked

Permanently distinct historical meanings. The difference is whether trust ever
existed.

| | **Rejected** | **Revoked** |
|---|---|---|
| Was trust granted? | **Never granted** | **Previously granted**, then withdrawn |
| What exists in history | A considered denial | A grant, and its withdrawal |
| Can it be re-proposed? | Yes, as a new decision | Yes, as a **new lineage** |

**Rejected** means approval was considered and denied. The subject never became
trusted under that decision, so there is no grant to withdraw.

**Revoked** means previously granted trust was explicitly withdrawn. A grant
existed and was relied upon.

A revoked subject may be trusted again — but only through a **new decision
producing a new record**, with its own evidence and its own approval. That new
record **references the revoked one and does not mutate it**. The revoked record
itself never returns to `Trusted`.

Revocation never deletes anything. The revocation is usually the most
interesting entry in a subject's history.

### Worked examples

**Rejected.** A proposed third-party model adapter was reviewed and denied
before receiving any authority. It never ran, never held a scope, and there is
nothing to withdraw — only a record that the question was asked and answered.

**Revoked.** A previously approved collector plugin was later found compromised
and its granted trust was withdrawn. The original grant stays readable, because
"what were we relying on before we found out" is the first question asked
afterwards.

## Only Expired may be reached by time

`Expired` is the single state the passage of time can produce, and only against
an expiration that was recorded when the grant was made.

**Expiry is not a renewal trigger.** An expired subject requires a new decision.
An expiry that renews itself measures nothing; expiry exists to force a look.

## Every other transition requires a decision

**No state transition may be automatic.** In particular, nothing returns to
`Trusted` because the condition that caused a change went away — a quarantined
subject does not un-quarantine when the alert clears, and a revoked one does not
return when the incident closes.

This is the **no automatic recovery** principle. A problem stopping being
*visible* is not the same as it stopping.

## Permitted transitions

Transitions are declared per domain in a [trust policy](../../platform-model/schemas/trust-policy.schema.yaml)
as explicit from/to pairs. No transition may be marked automatic, and any
transition *into* `Trusted` always requires a decision.

```
Unknown ──────► Pending ──────► Trusted ◄─────── Restricted
   │               │               │                  │
   │               ▼               ▼                  │
   │            Rejected      Quarantined ◄───────────┘
   │                               │
   │                               ▼
   └──────────────────────────► Revoked

  Trusted / Restricted ──(time only)──► Expired
```

Every arrow above except the one marked *time only* requires a trust decision
recording all eleven mandatory elements.

## Related

- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [The Trust Plane](trust-plane.md)
- [Trust domains](trust-domains.md)
