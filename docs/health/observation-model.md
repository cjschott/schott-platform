# Observation Model

**Architecture only.** No collector, probe, or evaluation loop exists.
Governed by [ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Health is built on the platform's existing evidence-first architecture rather
than a parallel metrics pipeline.

## Observation is evidence; state is derived

**A `capability-health-observation` is one measurement**, of one dimension, of
one subject, at one moment, from one **governed** source.

The source is a **`collector_id`** drawn from the platform's existing closed
collector registry, carried with a **`source_fingerprint`** — the same two fields
the released `observation` schema already requires, reused rather than
reinvented. A free-text source is not an identity: it cannot be weighed against a
contradicting one, and it lets a forged observation name any origin it likes. An
unregistered `collector_id` is refused.

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

### When two collectors disagree

Two or more **fresh** observations of the same dimension for the same subject,
from different collectors, disagreeing about the declared condition, produce
**`unknown`** for that dimension — citing every contradicting observation, with
review required.

*Newest wins* was rejected because it lets a compromised collector win simply by
writing last, which is the cheapest attack available. *Trusted-source
precedence* was rejected because it would make Health read trust standing as an
input to a health verdict, which is the direction ADR-0011 exists to keep closed.
Uncertainty must become **neither a positive claim nor positive evidence for
removal**.

The cost is accepted and named: one compromised collector can force a dimension
to `unknown` and so prevent `healthy`. That is a denial of *reassurance*, not of
service — it removes no candidate — and it is the right trade against letting a
forged observation establish health.

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
- **success count** and **failure count** — outcomes over a declared window,
  read from capability execution results by a Health-side collector

**Execution outcomes reach Health by being read, never by being pushed.** The
Capability Runtime is barred from this plane and its suite enforces that by
module name; the only permitted direction is Health reading Capability.

**Only a failure attributable to the capability instance counts.** A governed
`refused` is the platform working correctly, and counting it as degradation would
let anyone who can provoke refusals manufacture a finding. A `cancelled` is
someone else's decision. An adapter or serialisation failure is **Kyri's**
failure, and reading it as the subject's is the same mistake as a collector
reporting its own outage as the host being broken. A `timeout` or an
`interrupted` is **ambiguous** — a hanging provider or a misconfigured
supervisor — and nothing in the record distinguishes them, so neither is
attributed. The normative mapping is in
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

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

### Which subjects a dimension may describe

**Every dimension here describes a running thing — an instance or a host.** A
`capability-package` is **not** a subject of operational health: an
`availability` or `latency` observation about a package would be a claim about
something that does not run, and a non-running artifact must not be labelled
healthy.

**Package integrity and verification evidence belong to the Integrity plane**,
not here. They answer "is this artifact what it claims to be", which is a
different question from whether a live instance is working, and collapsing them
would let a verified package read as an available one. This is the same reasoning
that reconciled `endpoint-health` into a dimension of the instance an endpoint is
reached through, rather than shipping a schema whose subject does not exist.

The subject constraint is declared on the schema as a dimension/subject matrix
rather than left to a collector's judgement, and it is consistent across every
Health record family.

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

### What makes a claim worth anything

**Neither timestamp alone is sufficient.** If freshness came from the subject's
own `observed_at`, the subject would choose the number deciding its own liveness.
If freshness came from a receipt time with no replay protection, a **replayed**
old heartbeat would arrive now and read as fresh. Each closes the other's hole:

- **`observed_at` is the subject's claim**, retained for audit and **never** an
  input to heartbeat freshness.
- **`received_at` is Health-authored** at the receiving surface and is the **only**
  input to heartbeat freshness. Subject clock skew is therefore irrelevant by
  construction.
- **`epoch` is Health-authored**, bound to the authenticated session the
  heartbeat arrived in. **A subject cannot advance its own epoch** — a counter it
  controlled would let it replay an old sequence by claiming a new epoch.
- **`sequence` is the subject's**, and must strictly increase within an epoch. A
  pair already seen is refused, so a replay never acquires a `received_at`.
- **A restart advances the epoch only by re-authenticating**, and establishing an
  authenticated session is itself evidence that something is alive.
- **`subject_id` is bound to the authenticated channel**, or any subject could
  heartbeat on another's behalf.

### A subject cannot certify itself

**`healthy` requires at least one satisfied dimension measured by something other
than the subject.** Heartbeat freshness may support **bounded liveness**; it can
never, alone, support a `healthy` conclusion, and no subject self-report
independently establishes Health standing.

An envelope declaring only subject-reported dimensions yields
`insufficient-policy`: an envelope that cannot tell "alive" from "working" has
not declared enough to assert health. Visible, inert, and it creates pressure to
finish the envelope.

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
