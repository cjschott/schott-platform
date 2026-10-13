# ADR-0019: The Health Condition and Hysteresis Grammar

- **Status:** Accepted
- **Date:** 2026-10-13
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved.

> **This ADR defines a policy language, not a runtime.** Nothing here is
> implemented: no evaluator, no envelope authoring tool, no derivation. It exists
> because [ADR-0013](ADR-0013-capability-health-plane.md) requires health
> evaluation to be deterministic and reproducible from cited evidence, and
> required `entry_condition`, `exit_condition` and `hysteresis` on every envelope
> dimension **without saying what they are**. A deterministic evaluator cannot be
> built on free text.

## Context

ADR-0013 states that a health state is "a deterministic function of its cited
observations and the envelope it was evaluated against. Identical inputs produce
an identical state, every time", and the degradation rules add that "a transition
an operator cannot reproduce from the cited evidence is one they cannot argue
with, which makes it useless during a review."

The envelope schema shipped with three required fields and no grammar for any of
them. The only exemplars were free text — `"p95 > 2000ms"` and `"> 32"` — in two
different shapes, one carrying its unit inside the string.

**The problem is not that a grammar is missing. It is that a grammar is a policy
surface.** Every token a parser accepts is a semantic commitment, and every token
it quietly rejects makes an operator's envelope silently unenforceable. ADR-0013
reserves thresholds to a human: "Thresholds are human-declared." An implementer
choosing what `p95` means would be authoring the threshold, which is the thing
that was reserved.

There is a second problem that only appears on inspection. `"p95 > 2000ms"`
requires percentile aggregation over a sample set, and a
`capability-health-observation` is defined as "one measurement, of one dimension,
of one subject, at one **moment**". The exemplar cannot be evaluated against the
record the architecture defines as its input.

## Decision

**Conditions are structured declarations, not expression strings.** There is no
parser, because the smallest thing that satisfies "same inputs, same state, every
time" is a form that cannot be mis-parsed.

```yaml
dimension: latency
unit: milliseconds
aggregation: { kind: instant }
entry_condition: { operator: gt, value: "2000" }
exit_condition:  { operator: le, value: "1500" }
hysteresis: { kind: duration, seconds: 120, max_gap_seconds: 30, min_samples: 3 }
freshness_policy_seconds: 60
```

### Comparison operators

Closed, five:

| Operator | Meaning |
|---|---|
| `gt` | greater than |
| `ge` | greater than or equal |
| `lt` | less than |
| `le` | less than or equal |
| `eq` | equal |

No `ne`, no ranges, no boolean combinators, no negation. A dimension needing two
bounds declares two dimensions, or uses the asymmetry between `entry_condition`
and `exit_condition`, which is what that asymmetry is for.

### Numeric representation

A **decimal string**, compared as an exact decimal. Not a binary float: `0.1` must
not depend on representation, and a threshold that compares differently on two
hosts is not deterministic. Integers are decimal strings with no fractional part.

### Units, and dimension compatibility

Each dimension has exactly one declared unit. **The envelope's `unit` must equal
the observation's `unit`; a mismatch is refused, never converted.** Implicit
conversion is how `2000ms` and `2s` become a silent disagreement.

| Dimension | Unit |
|---|---|
| `availability` | `boolean` |
| `heartbeat-freshness` | `seconds` |
| `transport-health` | `boolean` |
| `latency` | `milliseconds` |
| `queue-depth` | `items` |
| `success-count` | `count` |
| `failure-count` | `count` |
| `cpu-utilization` | `percent` |
| `memory-utilization` | `percent` |
| `gpu-utilization` | `percent` |
| `vram-utilization` | `percent` |
| `storage-pressure` | `percent` |
| `collector-freshness` | `seconds` |

### Aggregation

Closed, **two**.

**`instant`** — evaluate the single newest observation for that dimension whose
`collection_status` is `collected` and whose age is within
`freshness_policy_seconds`. If there is none, the dimension is **`unknown`**:
never `healthy`, never `degraded`.

**`windowed_count`** — `{ kind: windowed_count, window_seconds: n,
min_samples: m }`. Applies to `success-count` and `failure-count`, which the
observation model already defines as outcomes over a declared window. The
comparison applies to the **count of qualifying observations** in the window.
`min_samples` is **required**: a window holding fewer usable observations yields
**`unknown`**, because one sample in an empty window is not a verdict.

**Window boundaries are half-open, start-inclusive and end-exclusive**, anchored
at the evaluation instant: `[evaluated_at − window_seconds, evaluated_at)`. This
reuses the convention `capability-route` already declares for its overlap window
rather than inventing a second one.

### Percentiles are not supported

**`p95` and every other percentile aggregation are excluded from this release**,
and the worked example that used one is corrected.

Three reasons. It is **not expressible** against an observation model whose record
is one measurement at one moment, and nothing declares which observations would
form the sample set. **"p95" is not one definition** — nearest-rank, linear
interpolation, and exclusive versus inclusive conventions give different answers
on the same samples, and the difference is largest on small sets, which is the
regime a fleet of a few instances lives in. And **hysteresis already does the job
a percentile was reaching for**: the reason to want one is to avoid degrading on a
single slow response, which is exactly what ADR-0013 requires hysteresis for.
`{instant, gt, "2000"}` with a 120-second duration expresses "latency has been
over 2000ms for two minutes" — the operationally meaningful claim, reproducible
from cited observations by inspection.

A future `percentile` aggregation with a required, named interpolation convention
would not invalidate any envelope written under this ADR.

### Combination across dimensions

Unchanged from ADR-0013: `worst-dimension-wins`. Any dimension outside its limit
degrades the subject. Any dimension that is `unknown` prevents `healthy`.

### Hysteresis

A subject that crosses a boundary once has not degraded, and the declared
condition says for how long it must hold.

| Kind | Supported in v1 |
|---|---|
| `duration` | yes |
| `occurrences` | no |


```yaml
hysteresis: { kind: duration, seconds: 120, max_gap_seconds: 30, min_samples: 3 }
```

All four members are **required**. `occurrences` — "how often" — is **not
supported in v1**: with `instant` conditions and a duration, and with the two
count dimensions carrying their own window through `windowed_count`, "how often"
is expressed in the *condition* rather than in the hysteresis. Supporting both
would mean two proof shapes, two evaluation paths and a discriminator, for a case
nothing has needed. It remains additively available.

#### Continuity: a gap is not a violation

**Two observations separated by a long gap do not establish continuous threshold
violation.** This is the rule that makes a duration hysteresis honest, and without
it a collector outage would manufacture transitions.

A candidate interval `[t0, t1]` satisfies the hysteresis only when **all** of:

1. **Duration** — `t1 − t0 ≥ seconds`.
2. **Violation throughout** — every **usable** observation of that dimension in
   the interval violates the `entry_condition`. A usable observation is one with
   `collection_status: collected`, a `measured_value`, and an age within
   `freshness_policy_seconds`.
3. **Minimum coverage** — the interval contains at least `min_samples` usable
   observations. A declared duration with two samples ninety seconds apart is not
   evidence of a continuous condition; it is two measurements and an assumption.
4. **Maximum gap** — no two consecutive usable observations in the interval are
   more than `max_gap_seconds` apart, **and** the first is within
   `max_gap_seconds` of `t0`, **and** the last is within `max_gap_seconds` of
   `t1`. The boundary clauses matter: without them an interval could be padded at
   either end by time nothing was measured.

#### Interruption and reset

The interval **resets** — `t0` moves to the next violating usable observation — on
any of:

- a usable observation that does **not** violate the `entry_condition`;
- a gap between consecutive usable observations exceeding `max_gap_seconds`;
- a gap exceeding `max_gap_seconds` between `t0` and the first usable
  observation, or between the last and `t1`.

**A gap resets the interval regardless of why it exists** — whether no observation
was taken, or only unusable ones were. This is `collection_failure_implies_
subject_failure: false` enforced arithmetically: a collection outage produces a
gap in *usable* observations, the gap breaks continuity, and **a monitoring
failure therefore cannot produce a transition.** A monitor that manufactured
findings from its own outages would do so most enthusiastically during a network
incident, when its findings are least reliable.

Exit from a degraded state uses the `exit_condition` under the same four rules.
Entry and exit are separate thresholds because a single one used for both is what
produces flapping.

#### What a transition must record

A transition that cannot show its hysteresis was satisfied is **not recordable**.
Every `capability-degradation-event` therefore carries, as required fields:

| Field | Why |
|---|---|
| `hysteresis` | the resolved declaration, quoted, so the event stays readable after the envelope is superseded |
| `hysteresis_satisfied_over_seconds` | the achieved duration |
| `hysteresis_first_observation_id` | the interval's start |
| `hysteresis_last_observation_id` | the interval's end |
| `hysteresis_sample_count` | the usable observations in the interval, against `min_samples` |
| `hysteresis_observed_max_gap_seconds` | the largest gap, against `max_gap_seconds` |
| `derived_from_observation_ids` | the ordered interval, so the whole judgement is re-checkable |

An operator can recompute the verdict from these fields and the cited
observations without access to the evaluator. That is the test of reproducibility,
and the reason each parameter has a matching observed value beside it.

### Ordering

By `observed_at` ascending, ties broken by observation identifier ascending. Both
are total and recorded, so "newest" and "consecutive" are never ambiguous.

### Rounding

**None is required, by construction.** This grammar performs no division, no
averaging and no interpolation, so there is no rounding rule to declare. That is a
consequence of the aggregation set rather than an omission, and it is the main
practical argument for keeping percentiles out.

### Contradicting sources

Not resolved here. ADR-0013 owns source identity and declares that contradicting
fresh observations of one dimension from different collectors yield `unknown`.
**This grammar receives that result and must not resolve contradictions itself**,
because a grammar that picked a winner would be authoring policy.

## Rejected Alternatives

**A string mini-language with a published BNF.** Buys expressiveness nothing has
asked for, and costs a parser, a test corpus, and a versioning story for the
language itself. Every one of those is a place a condition can mean something its
author did not intend.

**Percentiles with a declared interpolation convention.** Defensible, and strictly
larger. It should wait for a subject whose envelope genuinely cannot be written in
instant form; none exists.

**Free text with a human-reviewed evaluator per dimension.** Not determinism —
determinism per installation.

**Both hysteresis kinds in v1.** Two proof shapes on the transition record and a
discriminator, for a distinction the condition can already express.

**Defaulted `max_gap_seconds` and `min_samples`.** The tempting shortcut, and the
same mistake the Null Policy Rule exists to prevent: a defaulted continuity
parameter is an unanswered configuration question rendered as a confident
assessment. Both are required, and an envelope that omits either is refused.

## Consequences

**Positive.** Health evaluation becomes reproducible by hand from a transition
record and its cited observations. There is no parser to disagree with itself. A
monitoring outage cannot manufacture a transition, because a gap breaks
continuity. No rounding rule exists to get wrong.

**Negative.** Envelopes are more verbose than a string, and every dimension needs
four hysteresis members written down. The worked example that used `p95` has to be
corrected rather than supported. An operator who wants a percentile cannot have
one in this release.

**Accepted consequences.**

- **A hand-authored limit is still a guess.** This ADR makes the guess precise and
  reproducible; it does not make it correct.
- **Verbosity is the cost of determinism.** A condition nobody can mis-parse is
  longer than one nobody can evaluate.
- **Required continuity parameters will feel like bureaucracy** until the first
  incident where a collector outage would otherwise have produced a transition.

## Related

- [ADR-0013: The Capability Health Plane](ADR-0013-capability-health-plane.md)
- [Operational envelope](../health/operational-envelope.md)
- [Degradation semantics](../health/degradation-semantics.md)
- [Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
