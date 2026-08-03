# Health States

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Six states. **`unknown` is the default.**

| State | Meaning | Healthy? | Effect on eligibility |
|---|---|---|---|
| `unknown` | No fresh observation exists. | No | **Inert** — neither qualifies nor disqualifies |
| `unmonitored` | No envelope declared; health is not assessable. | No | **Inert** |
| `healthy` | Within the declared envelope on every measured dimension. | Yes | None — health never adds |
| `degraded` | Outside the envelope on at least one dimension, still responding. | No | May remove, per route policy |
| `unavailable` | Not responding, or heartbeat stale beyond its declared threshold. | No | **Removes** the candidate |
| `withheld` | Operator set the host's availability intent to draining or withheld. | Not a health finding | Removes, by operator intent |

## unknown is never healthy, and it is inert

The two most important properties of this table, and they pull in opposite
directions on purpose.

**`unknown` is never healthy.** The layer never asserts that something is
working without evidence that it is.

**`unknown` is also inert.** It does not remove a candidate. The alternatives
are both worse:

- **If `unknown` removed candidates**, losing the health collector would empty
  every route at once. A monitoring failure would become a platform outage, and
  an attacker wanting to disable the fabric would attack the monitor.
- **If `unknown` counted as healthy**, an unmonitored node would be
  indistinguishable from a verified-good one, and the cheapest way to look
  healthy would be to stop reporting.

So health is **fail-closed on claims and inert on eligibility**. Eligibility
remains the Trust Plane's fail-closed gate; health only ever subtracts from
what trust already allowed, and only when it has something to show.

## unknown versus unmonitored

Both are non-healthy and both are inert, and the difference is worth keeping.

- **`unknown`** — we should know and do not. Observations are missing, stale,
  or the collection failed.
- **`unmonitored`** — there is nothing to know *against*. No envelope has been
  declared, so no measurement can be called inside or outside.

This mirrors the Null Policy Rule in the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md):
the absence of a policy produces an explicit "not defined", never a favourable
default. `unmonitored` is visible so that it creates pressure to write an
envelope, rather than hiding as a quiet pass.

## withheld is reported, not derived

`withheld` reflects the operator's `availability_intent` on the capability
host. The Health Plane does not decide it and cannot set it.

It exists so that **"withdrawn on purpose" is never displayed as "broken"** — a
distinction that matters most during a planned maintenance window, when every
other signal looks like an incident.

## These are not trust states

Health states and **trust state** are separate vocabularies over separate
questions, and neither maps onto the other.

| | Trust asks | Health asks |
|---|---|---|
| Question | May this subject participate? | Is it working right now? |
| Set | Eight states, defined in ADR-0011 | The six above |
| Changed by | A trust decision, by a human authority | Deterministic evaluation of evidence |
| Default | `Unknown`, which fails closed | `unknown`, which is inert |

A subject that is quarantined and `healthy` is quarantined. A subject that is
trusted and `unavailable` is trusted. Reporting either as the other destroys
the distinction an operator needs during an incident.

## Transitions

- Every transition between health states produces a
  [degradation event](degradation-semantics.md), including recovery.
- Transitions are **deterministic**: identical observations and envelope
  produce identical states.
- A state is **superseded, never edited**, so what was believed at the moment
  of a past routing decision stays answerable.
- **No transition is automatic in the sense of causing an action.** A state
  change is a record. Acting on it is a human's job.

## Related

- [Capability Health overview](capability-health.md)
- [Observation model](observation-model.md)
- [Degradation semantics](degradation-semantics.md)
- [Trust states](../trust/trust-states.md)
