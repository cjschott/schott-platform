# Observation Model

**Architecture only.** No collector, probe, or evaluation loop exists.
Governed by [ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Health is built on the platform's existing evidence-first architecture rather
than a parallel metrics pipeline.

## Observation is evidence; state is derived

**A `capability-health-observation` is one measurement**, of one dimension, of
one subject, at one moment, from one named source.

It **carries no verdict** — no state, no conclusion, no score. An observation
that concluded would be a measurement that had already decided, and the
evidence behind an assessment would be inseparable from the assessment.

**A `capability-health-state` is derived** from those observations, against a
declared envelope, deterministically. It records the observation identifiers it
came from, so any assessment can be re-checked against the evidence that
produced it.

## A collection failure is not a subject failure

The rule the
[Collector Plugin Standard](../standards/collector-plugin-standard.md)
establishes one layer down, and it matters more here than anywhere.

Every observation carries a `collection_status`:

| Status | Meaning |
|---|---|
| `collected` | A measurement was taken. |
| `failed` | Collection failed. **Says nothing about the subject.** |
| `unavailable` | The subject could not be reached. **Still says nothing about the subject's health.** |

A collector that cannot reach a host records that it failed. It concludes
nothing about the host.

A monitor that read its own outage as the subject being broken would
manufacture findings out of its own failures — and would do so most
enthusiastically during a network incident, when its findings are least
reliable and most likely to be acted on.

A failed collection has **no measured value**. Recording a zero would be
inventing one.

## Observed dimensions

### Availability and liveness

- **availability** — whether the subject answered
- **heartbeat-freshness** — how long since the subject's last liveness claim
- **transport health** — the health of the path, held separately from the
  subject, because the same subject reached by a different transport is a
  different question

### Performance

- **latency** — observed response time
- **queue depth** — work waiting at the subject
- **success count** and **failure count** — outcomes over a declared window

These are measurements, not a scheduling input. The Fabric's candidate order is
human-authored and **health may never reorder it**.

### Resource pressure

- **CPU utilization**
- **memory utilization**
- **GPU utilization**
- **VRAM utilization**
- **storage pressure**

Expressed against the host's declared resource profile, in the same controlled
vocabulary the Fabric uses, so a heterogeneous fleet is comparable without
naming any vendor.

### The observability layer observing itself

- **collector freshness** — how current the health data itself is

A stale collector is a fact about the collector, not about the subject. Without
this dimension, an operator cannot distinguish "the subject is quiet" from "we
stopped listening".

## Freshness

Reuses the four states from the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
rather than inventing a fifth vocabulary for the same idea:

`current` · `aging` · `stale` · `unknown`

The **Null Policy Rule** is inherited exactly: a dimension with **no freshness
policy** produces `unknown`, never a default maximum age. Inventing an age
would convert an unanswered configuration question into a confident-looking
assessment, and the resulting label would be fabricated.

The freshness of nothing is `unknown`, never `stale`. Stale means "we looked
and it was long ago"; unknown means "we have not looked".

## Heartbeats are claims

A `capability-heartbeat` is a subject's liveness signal **about itself**. Like a
capability advertisement, it is a claim and never a grant: it confers no trust,
no eligibility, and no standing.

A subject saying it is alive is evidence that something sent a message, which
is not the same as the capability working. That is why heartbeat freshness is
one dimension among several rather than the definition of health.

**An absent heartbeat is `unknown`, never healthy** — and not proof of failure
either. It is the absence of a signal.

## Determinism

A health state is a deterministic function of its cited observations and the
envelope it was evaluated against. Identical inputs produce an identical state,
every time.

No scoring. No weighting the platform chose. No machine-learned anomaly
detection. No thresholds derived from the subject's own history.

## Related

- [Capability Health overview](capability-health.md)
- [Operational envelope](operational-envelope.md)
- [Health states](health-states.md)
- [Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
