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
| **Trusted** | Explicitly approved, in scope, unexpired. | Yes, within scope | An approving decision |
| **Restricted** | Trusted for a narrower scope than was requested. | Yes, within the narrowed scope | A decision granting less than asked |
| **Quarantined** | Previously trusted, temporarily withheld pending investigation. | No | A decision, never automatically |
| **Revoked** | Trust withdrawn. Terminal for this record. | No | A revoking decision |
| **Expired** | The grant's expiration has passed. | No | Time, against a recorded expiration |
| **Rejected** | Trust was requested, considered, and refused. | No | A refusing decision |

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

Both are narrower than `Trusted`, and they mean different things:

- **Restricted** is a *grant*. The subject was evaluated and trusted for less
  than it asked for. It is a normal, expected outcome, not a problem.
- **Quarantined** is a *withdrawal*. The subject was trusted, something raised a
  question, and standing is withheld while that question is open.

Reporting one as the other loses the distinction between "we deliberately gave
it less" and "we are worried about it".

> These two may prove to overlap in practice. ADR-0011 records that as an
> accepted risk, and the schemas permit a later ADR to narrow them.

## Revoked is terminal for the record

A revoked subject may be trusted again — but only through a **new decision
producing a new record**, with its own evidence and its own approval. The
revoked record itself never returns to `Trusted`.

Revocation never deletes anything. The revocation is usually the most
interesting entry in a subject's history.

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
