# ADR-0013: The Capability Health Plane

- **Status:** Accepted
- **Date:** 2026-08-03
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved.

> **This ADR defines architecture only. There is no runtime implementation in
> this release** — no health engine, no collectors, no probes, no heartbeat
> receiver, no evaluation loop, no rerouting, no drain, no quarantine, no
> remediation. This document plus the six schemas are the specification; a
> future engineer should be able to build the Health Plane from them without
> inventing behaviour or redesigning it.

## Context

v0.9.5 defined where a capability may execute. It could not say whether the
thing it selected was working, and it deliberately did not try: ADR-0012 gave
health exactly one power — to remove a candidate — and left the definition of
health to this release.

That restraint has a cost that is now visible. A route lists candidates in
declared order and takes the first eligible one. If the first candidate is
trusted, admitted, and silently broken, the fabric selects it every time, and
the operator's only signal is that requests fail. The platform can say what it
is permitted to do and not whether it is doing it.

The obvious fix is the dangerous one. A monitor that notices a broken node and
reroutes around it is what every operator wants at three in the morning, and it
is an autonomous controller wearing an observability label. **Availability data
is the easiest signal in the platform to manipulate from outside** — a node
that wants work need only look healthy, and a node that wants to shed work need
only look sick. Anything that acts on that signal automatically has handed the
decision to whoever can influence it.

There is a second, quieter risk. Health is a *number-shaped* domain: latency,
queue depth, utilisation, success rate. Numbers invite thresholds, thresholds
invite tuning, and tuning invites learning them from observed behaviour. A
threshold the platform derived from a node's own history is a threshold that
node chose, and "degraded" then means "different from how it has been
behaving", which is not a statement about whether it works.

## Decision

Health becomes a **governed observational layer**: the **Capability Health
Plane**, beside Observation, Knowledge, Integrity, Experience, Occurrence,
Trust, and the Fabric.

> **Capability health describes whether a trusted capability is available and
> behaving within its declared operational envelope.**
> **Health never grants trust, and trust never implies health.**

These are two axes, not one scale. A subject may be **trusted and healthy**,
**trusted and degraded**, **trusted and unavailable**, or **restricted and
healthy**. A quarantined subject cannot be made usable by any health status,
however good. An untrusted subject cannot be made eligible by excellent health.

**Health must never override trust. Where the two disagree, trust decides.**

### Trust, Fabric, and Health

| Layer | Question | May it grant eligibility? |
|---|---|---|
| **Trust Plane** (ADR-0011) | May this subject participate? | Yes — it is the only thing that may |
| **Capability Fabric** (ADR-0012) | Where may this workload execute? | No — it narrows what trust allowed |
| **Health Plane** (this ADR) | Is the trusted capability currently available and operating within its declared limits? | No — it may only remove, and only on evidence |

The direction never reverses:

- **Health cannot grant trust.**
- **Health cannot change trust state**, in either direction.
- **Health cannot override quarantine.**
- **Health cannot broaden scope.**
- **Health cannot admit a node**, register a capability, or create an instance.
- **The Trust Plane does not use health records as evidence of
  trustworthiness.** A capability that has been healthy for six months has
  earned nothing; a compromised capability's most likely behaviour is to look
  well.

### The observation model

Health is built on the platform's existing evidence-first architecture rather
than a parallel metrics pipeline.

**A `capability-health-observation` is evidence.** One measurement, of one
dimension, of one subject, at one moment, from one named source. It is
immutable, and it **carries no verdict** — no state, no conclusion, no score.
An observation that concluded would be a measurement that had already decided.

**A `capability-health-state` is derived.** It is a deterministic function of
the observations cited on it and the envelope it was evaluated against. Same
inputs, same state, every time. It records the observation identifiers it was
derived from, so any state can be re-checked against the evidence that produced
it.

**A collection failure is not a subject failure.** This is the collector
standard's rule, one layer up, and it matters more here than anywhere. A
collector that cannot reach a host records `collection_status: failed`; it
concludes nothing about the host. A monitor that read its own outage as the
subject being broken would manufacture findings out of its own failures — and
would do so most enthusiastically during a network incident, when its findings
are least reliable and most likely to be acted on.

**Freshness reuses the existing four states** — `current`, `aging`, `stale`,
`unknown` — and the **Null Policy Rule** from the Confidence and Freshness
Standard. A dimension with no declared policy produces `unknown`, never a
default maximum age. Inventing an age would convert an unanswered configuration
question into a confident-looking assessment.

### The operational envelope

Health is meaningless without a declared limit to be inside or outside of.

A **`capability-health-envelope`** declares, per dimension, what acceptable
looks like for one subject. It is **authored by a human** and **never learned**:
no baseline, no anomaly model, no threshold derived from the subject's own
history. A threshold a node taught the platform is a threshold that node chose.

**A subject with no envelope is `unmonitored`, not healthy.** There is nothing
to compare against, and saying so is the honest answer. This mirrors the Null
Policy Rule exactly: absence of a policy produces an explicit "we have not
defined this", never a favourable default.

### Health states

Six states. **`unknown` is the default.**

| State | Meaning | Healthy? |
|---|---|---|
| `unknown` | No fresh observation exists. | No |
| `unmonitored` | No envelope declared; health is not assessable. | No |
| `healthy` | Within the declared envelope on every measured dimension. | Yes |
| `degraded` | Outside the envelope on at least one dimension, still responding. | No |
| `unavailable` | Not responding, or heartbeat stale beyond its declared threshold. | No |
| `withheld` | The operator set the host's availability intent to draining or withheld. | Not a health finding |

`withheld` is **reported, not derived**. It exists so that "not serving because
an operator withdrew it" is never displayed as "not serving because it is
broken" — a distinction that matters most during a planned maintenance window,
when every other signal looks like an incident.

### Why unknown does not remove a candidate

The load-bearing decision of this layer, and the one most likely to be
reversed by someone who has not thought it through.

**Health may remove a candidate only on a fresh, positive observation.
`unknown` neither qualifies nor disqualifies — it is inert with respect to
eligibility.**

The two alternatives are both worse:

- **If `unknown` removed candidates**, losing the health collector would empty
  every route at once. A monitoring failure would become a platform outage, and
  the blast radius of the observability layer would exceed that of the thing it
  observes. An attacker wanting to disable the fabric would attack the monitor.
- **If `unknown` counted as healthy**, an unmonitored node would be
  indistinguishable from a verified-good one, and the cheapest way to look
  healthy would be to stop reporting.

So health is **fail-closed on claims and inert on eligibility**. It never
asserts healthy without evidence, and it never changes routing without
evidence. Eligibility remains the Trust Plane's fail-closed gate; health only
ever subtracts from what trust already allowed, and only when it has something
to show.

### Degradation semantics

Degradation is a **recorded transition**, not a status flag.

- **Entry and exit conditions are declared** on the envelope, separately. A
  single threshold used for both is what produces flapping.
- **Hysteresis is required**, not optional. A subject that crosses a boundary
  once has not degraded; the declared condition says how long or how often.
- **Every transition produces a `capability-degradation-event`** naming the
  dimension, the direction, the entry condition met, and the observations it
  was derived from.
- **A degradation event describes observed history and never the future.** It
  is not a warning that something will fail. The Occurrence and Experience
  layers already refuse to predict; health refuses for the same reason.

### The only output

**A `capability-health-recommendation` is the single thing this layer produces
that touches operations, and it is a record rather than an act.**

- It may recommend **`investigate`** or **`drain`**. Nothing else.
- It **may never propose** quarantine, revocation, rerouting, restart, or
  remediation. Those are trust decisions or fabric changes, and neither belongs
  to an observer.
- It **requires a human to act on it**. It is never executed automatically.

Stated as the roadmap reservation stated it: the Health Monitor **may recommend
investigation or draining**.
The Health Monitor **cannot execute remediation**.

That asymmetry is the whole design. A monitor that can change trust is a
monitor that can be induced to grant it.

### Reconciling the v0.9.6 reservation

The roadmap reserved seven entity names before the Fabric existed. Four survive
as written, and three are reconciled here rather than shipped with nothing to
refer to:

| Reserved | Outcome |
|---|---|
| `capability-health-observation` | Kept |
| `capability-health-state` | Kept |
| `degradation-event` | Kept as `capability-degradation-event`, namespaced with the rest |
| `node-heartbeat` | Generalised to `capability-heartbeat`; instances have liveness too, and one record with a subject type beats two nearly identical ones |
| `endpoint-health` | **Not an entity.** An endpoint is reached through an instance, so endpoint health is an observation dimension of that instance |
| `lease-health` | **Not an entity.** v0.9.5 deliberately defined no lease; there is nothing to observe |
| `placement-health` | **Not an entity.** v0.9.5 defined no placement record; selections are observed instead |

Shipping `lease-health` and `placement-health` would have created schemas whose
subjects do not exist, which is the specification equivalent of a dangling
reference.

Two new entities were added that the reservation did not anticipate: the
**envelope**, because "within its declared operational envelope" is unusable
without a record of the envelope; and the **recommendation**, because the
reservation granted the power to recommend without saying what a recommendation
is.

### Audit requirements

Every health record is immutable, append-only, and superseded rather than
edited. States carry the observation identifiers they were derived from, so the
evidence behind any past assessment stays reachable.

Three questions must be answerable from records alone:

- **"Was this capability healthy when that request was routed to it?"**
- **"What evidence did that assessment rest on?"**
- **"Who was told, and what did they do about it?"**

A health history that can be edited cannot answer the first one, which is the
only one that matters after an incident.

### Explicitly forbidden

- **No automatic rerouting** and no automatic workload rerouting.
- **No automatic drain.**
- **No automatic quarantine.**
- **No automatic node admission.**
- **No automatic trust changes**, in either direction.
- **No autonomous remediation** — no restart, redeploy, requeue, or repair.
- **No prediction.**
- **No forecasting** of availability, capacity, or demand.
- **No machine-learned anomaly detection**, and no learned thresholds.
- **No health scores.** A number expressing degree of health invites a
  threshold nobody chose to become the operational boundary.
- **No collector concluding about a subject it could not reach.**

## Rejected Alternatives

**Health-aware automatic failover.** The single most requested behaviour, and
the reason this layer is dangerous. It makes the most manipulable signal in the
platform into a placement authority. Health may remove a candidate; the
declared route order decides what happens next.

**Learned baselines and anomaly detection.** The platform already computes
baselines in the Experience layer, so the machinery exists. Using it here would
mean "degraded" is defined as "unlike its own recent behaviour", which is a
statement about change rather than about function — and a subject that degrades
slowly enough teaches the baseline that its new behaviour is normal.

**A health score.** Attractive because it collapses many dimensions into one
sortable number, and rejected for exactly the reason ADR-0011 rejected trust
scores: the threshold becomes the real policy, and nobody chose it.

**Treating unknown as unhealthy.** Superficially the cautious choice. It makes
the monitor a single point of failure for the entire fabric, and rewards
attacking the observer.

**Treating unknown as healthy.** Superficially pragmatic, and it makes not
reporting the cheapest way to look good.

**Health as a Trust Plane input.** A long clean health record feels like
evidence of trustworthiness. It is evidence of behaviour, which ADR-0011's
directionality rule exists to keep out of trust decisions.

**Letting health recommend quarantine.** A quarantine recommendation reads as
harmless because a human still approves it. In practice a stream of automated
quarantine recommendations trains the approver to click through them, which is
an automatic path with a human-shaped delay in it. Health recommends
investigation; a human decides what the investigation found.

**Building the health runtime in this release.** The schemas exist and the
rules are written. A partially built monitor is worse than none: it reads as
coverage while observing a subset, and the gap is invisible precisely where it
matters. Architecture ships first, as it did for the Trust Plane and the
Fabric.

## Consequences

**Positive.** The platform gains a defined answer to "is the thing we selected
working", separated from "is it allowed to run". Health assessments are
reproducible from cited evidence rather than asserted. The Fabric's existing
one-line contract with health — it may only remove — now has a specification
behind it. The envelope makes "degraded" mean something a human wrote down.

**Negative.** Every subject worth monitoring needs a hand-authored envelope,
and a subject without one reports `unmonitored` rather than passing quietly.
This will feel like bureaucracy until the first incident where a threshold
nobody chose would have hidden the problem. Nothing is automatic, so every
recommendation costs human attention.

**Accepted risks.**

- **A specification is not a control.** Nothing here enforces anything yet.
- **Six entity types is a large vocabulary for zero runtime**, and this is the
  second layer in a row to add one. The envelope and the recommendation are the
  two most likely to prove unnecessary; both are additive to remove.
- **Declared thresholds will be wrong at first.** Hand-authored limits are a
  guess until real traffic exists. They are at least a recorded guess with an
  author, which a learned threshold is not.
- **`withheld` overlaps with the Fabric's `availability_intent`** and may prove
  to be a duplicate view of one fact rather than a state of its own.
- **The inert treatment of `unknown` means a genuinely broken but unmonitored
  subject stays eligible.** That is the accepted cost of not letting a
  monitoring outage disable the platform, and it is why `unmonitored` is
  visible rather than quiet.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [ADR-0010: Remote Read-Only Collection](ADR-0010-remote-read-only-collection.md)
- [ADR-0011: The Trust Plane](ADR-0011-trust-plane.md)
- [ADR-0012: The Distributed Capability Fabric](ADR-0012-distributed-capability-fabric.md)
- [Capability Health overview](../health/capability-health.md)
- [Health states](../health/health-states.md)
- [Observation model](../health/observation-model.md)
- [Operational envelope](../health/operational-envelope.md)
- [Degradation semantics](../health/degradation-semantics.md)
- [Governance boundaries](../health/governance-boundaries.md)
- [Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
