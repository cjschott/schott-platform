# Degradation Semantics

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Degradation is a **recorded transition**, not a status flag.

## Entry and exit are separate

Each dimension of an [envelope](operational-envelope.md) declares an **entry
condition** and an **exit condition**, and they are not the same threshold.

A single threshold used for both directions produces **flapping**: a subject
sitting near the boundary crosses it repeatedly, generating a transition each
time. Flapping is worse than missing the problem, because the alert volume
trains an operator to ignore the signal — and it will be ignored on the
occasion it is real.

## Hysteresis is required

**Hysteresis is required, not optional.** A subject that crosses a boundary
once has not degraded.

The declared condition says how long, or how often, the boundary must be
exceeded before the transition is recorded. A transition that cannot show its
hysteresis was satisfied is not recordable.

## Every transition is recorded

A `capability-degradation-event` names:

- the **subject** and its type
- the **from state** and **to state**
- the **dimension** that moved — a transition with no dimension cannot be
  investigated
- the **entry condition** that was met, quoted from the envelope, so the event
  stays readable after the envelope is superseded
- the **observations it was derived from**

**Recovery is a transition too.** Moving from `degraded` back to `healthy`
produces an event, because "when did it come back, and on what evidence" is as
much an incident question as when it broke.

## Deterministic

Evaluation is **deterministic**: identical observations against an identical
envelope produce an identical transition, every time.

There is no scoring, no weighting the platform chose, and no
machine-learned anomaly detection. A transition an operator cannot reproduce
from the cited evidence is one they cannot argue with, which makes it useless
during a review.

## It describes observed history and never the future

**A degradation event is not a warning that something will fail.**

It records that a declared condition was met, at a time, on evidence. It
carries no probability, no time-to-failure, and no forecast.

The Occurrence and Experience layers already refuse to predict, and health
refuses for the same reason: a platform that forecasts failure will eventually
act on the forecast, and by then the forecast has become a placement input
derived from the most manipulable signal available.

Fields that would express prediction — `predicted_failure`, `forecast`,
`time_to_failure`, `probability`, `anomaly_score` — are forbidden on the
schema, not merely omitted from it.

## A degradation event causes nothing

Recording a transition does not drain, reroute, restart, quarantine, or
remediate anything. It may result in a
[recommendation](governance-boundaries.md) asking a human to look.

That is the end of the layer's authority.

## Related

- [Operational envelope](operational-envelope.md)
- [Health states](health-states.md)
- [Governance boundaries](governance-boundaries.md)
- [Observation model](observation-model.md)
