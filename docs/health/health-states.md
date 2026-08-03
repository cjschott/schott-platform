# Health States

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Seven states. **`unknown` is the default.**

| State | Meaning | Healthy? | Effect on eligibility |
|---|---|---|---|
| `unknown` | No fresh observation exists. | No | **Inert** — neither qualifies nor disqualifies |
| `unmonitored` | No envelope declared at all; health is not assessable. | No | **Inert** |
| `insufficient-policy` | An envelope exists but a metric it should govern has no declared threshold. | No | **Inert** |
| `healthy` | Within the declared envelope on every measured dimension. | Yes | None — health never adds |
| `degraded` | Outside the envelope on at least one dimension, still responding. | No | May remove, per route policy, on fresh evidence |
| `unavailable` | Not responding, or heartbeat stale beyond its declared threshold. | No | **Removes**, on fresh evidence |
| `withheld` | Health conclusions are intentionally not asserted or published. | Not a health finding | **Inert** — removes nothing on its own |

Only **`healthy`** supports a positive claim. Every other state is an absence
of one, and an absence must never be rendered as reassurance — see
[unknown health and freshness](unknown-and-freshness.md).

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

## unknown versus unmonitored versus insufficient-policy

Three ways of not having an answer, all non-healthy, all inert, and worth
keeping apart because they call for different fixes.

- **`unknown`** — we should know and do not. Observations are missing, stale,
  or the collection failed. *Fix the collection.*
- **`unmonitored`** — there is nothing to know *against*. No envelope has been
  declared at all. *Write an envelope.*
- **`insufficient-policy`** — an envelope exists, but a metric it should govern
  has no declared threshold. *Finish the envelope.*

All three mirror the Null Policy Rule in the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md):
the absence of a policy produces an explicit "not defined", never a favourable
default. The Null Policy Rule applies **per metric**, which is why
`insufficient-policy` exists at all — an envelope covering four dimensions and
declaring three must not report the fourth as satisfied.

All three are visible so that they create pressure to close the gap, rather
than passing quietly as though the subject had been checked.

## withheld is not the Fabric's availability intent

These were the same thing in the first draft, and that was wrong. A health
state meaning "the operator withdrew this node" is a second name for
`availability_intent`, and it makes a *health state* into a *selection
control*.

**`withheld` means health conclusions are intentionally not asserted or
published for this subject.**

| | Fabric `availability_intent` | Health `withheld` |
|---|---|---|
| **Owner** | The Fabric operator | The Health Plane |
| **Says** | Whether the capability should be offered for selection | Whether health conclusions are being asserted or published |
| **Controls selection** | **Yes** — it is the selection-control declaration | **No** |
| **Can set the other** | May influence whether Health evaluates or publishes | **Never** sets `availability_intent` |

Precisely:

- `withheld` **does not mean healthy.**
- `withheld` **does not mean degraded.**
- `withheld` **does not mean unavailable.**
- `withheld` **does not itself remove Fabric eligibility.**
- `withheld` is **not a synonym for do-not-select.**
- **Health cannot set** the Fabric availability intent.
- `availability_intent` **may** influence whether Health evaluates or publishes
  — a node an operator has withdrawn is a reasonable one to stop publishing
  conclusions about.

The two coincide often, and during a maintenance window both will read
`withheld`. They are still different facts, and the moment they diverge is
exactly when the distinction earns its keep. See
[worked example 4](worked-examples.md).

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
