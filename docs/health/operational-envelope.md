# The Operational Envelope

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Health is meaningless without a declared limit to be inside or outside of.
"Degraded" has to mean *outside something*, and that something must be written
down by a person.

## What an envelope is

A `capability-health-envelope` declares, per dimension, what acceptable looks
like for one subject.

Each dimension entry carries:

| Field | Purpose |
|---|---|
| `dimension` | Which measurement this governs |
| `unit` | What the numbers mean |
| `entry_condition` | When the subject becomes degraded on this dimension |
| `exit_condition` | When it stops being degraded |
| `hysteresis` | How long or how often the condition must hold |
| `freshness_policy_seconds` | Maximum age before observations are stale; **null is permitted** |

Entry and exit are **separate** because a single threshold used for both is
what produces flapping. Hysteresis is **required**, not optional: a subject
that crosses a boundary once has not degraded.

## Declared, never learned

**An envelope is authored by a human. Thresholds are never learned, derived, or
inferred from observed behaviour.**

The platform already computes baselines in the Experience layer, so the
machinery to learn thresholds exists. Using it here would be a mistake:

- A threshold derived from a subject's own history is **a threshold that
  subject chose**.
- "Degraded" would then mean **"unlike its own recent behaviour"**, which is a
  statement about change rather than about function.
- A subject that degrades slowly enough **teaches the baseline that its new
  behaviour is normal**, and the monitor stops noticing precisely as the
  problem gets worse.

A hand-authored limit will be wrong at first. It is at least a recorded guess
with an author, which a learned threshold is not.

## No envelope means unmonitored

**A subject with no envelope is `unmonitored`, not healthy.**

There is nothing to compare a measurement against, and saying so is the honest
answer. This mirrors the Null Policy Rule in the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
exactly: the absence of a policy produces an explicit "not defined", never a
favourable default.

`unmonitored` is deliberately visible. It creates pressure to write an
envelope, rather than passing quietly as though the subject had been checked.

## Evaluation

The declared limits combine into one state by `worst-dimension-wins`: any
dimension outside its limit degrades the subject.

That is the conservative rule and the only one defined in this release. A
weighted combination would require weights nobody chose, which is the
[health score](../decisions/ADR-0013-capability-health-plane.md) this
architecture refuses.

## What an envelope may never contain

- a **learned, automatic, baseline, or derived threshold**
- an **anomaly model** or anomaly score
- a **forecast** or predicted limit
- a **health score**
- a **trust state** — the envelope governs behaviour, never standing

## Related

- [Capability Health overview](capability-health.md)
- [Observation model](observation-model.md)
- [Degradation semantics](degradation-semantics.md)
- [Health states](health-states.md)
