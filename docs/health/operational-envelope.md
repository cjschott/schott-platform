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

### Experience may inform, but cannot author

The separation matters, because the useful half of the Experience layer is
available without the dangerous half.

| Experience **may** | Experience **may not** |
|---|---|
| be **referenced as supporting evidence** for a human's judgement | **write** an envelope |
| be read by an operator deciding where a threshold belongs | **mutate** an envelope |
| appear in the reasoning recorded alongside a threshold | have a **baseline promoted** to a threshold |

- **No baseline automatically becomes a threshold.** A person may look at one
  and choose the same number; that is a human decision with an author.
- **Frequent violations cannot widen a threshold.** A limit that relaxes
  because it keeps being exceeded measures nothing — the violations *are* the
  finding.
- **Envelope changes require immutable approval.** A new envelope version is a
  new record with an approving identity, not an edit.

## No envelope means unmonitored; no threshold means insufficient-policy

**A subject with no envelope is `unmonitored`, not healthy.** There is nothing
to compare a measurement against.

**A metric with no declared threshold produces `insufficient-policy`, never
`healthy`.** The Null Policy Rule applies **independently per metric**: an
envelope covering four dimensions and declaring three of them must not report
the fourth as satisfied.

Both mirror the Null Policy Rule in the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
exactly: the absence of a policy produces an explicit "not defined", never a
favourable default.

Both are deliberately visible. They create pressure to write or finish an
envelope, rather than passing quietly as though the subject had been checked.

## Supersession never reaches back

An envelope is **superseded, never edited**, and each version is numbered.

Every health state records the **envelope version** it was evaluated against.
That is what makes the following safe:

> **One observation evaluated against two envelope versions may yield two
> different results, and both remain auditable.**

A tightened threshold does not retroactively make last week's assessment wrong.
The old evaluation stands as what was believed at the time — which is precisely
what an incident review needs — and a re-evaluation is a new record rather than
a correction. See [worked example 7](worked-examples.md).

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
