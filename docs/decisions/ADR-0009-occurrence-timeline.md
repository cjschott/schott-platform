# ADR-0009: Occurrence Timeline

- **Status:** Accepted
- **Date:** 2026-08-02
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved. The
> gap is deliberate.

## Context

Four layers now describe the platform:

| Layer | Question |
|---|---|
| Evidence | What is true? |
| Knowledge | What do we believe, and why? |
| Operational Integrity | Is this still the system we confirmed was good? |
| Experience | Is this normal? |

None of them answers the question an operator asks first during an incident:
**has this happened before?**

Evidence records that a service restarted. Knowledge derives that it is
currently running. Integrity says the configuration matches its snapshot.
Experience says CPU is within its usual range. Every layer reports something
reasonable, and none of them says *this is the fourth restart today, and the
gaps are getting shorter*.

That information already exists in the platform — it is spread across evidence
timestamps and knowledge events, in a form nobody can read without
reconstructing it by hand. Making time a first-class concept is mostly a matter
of stopping the discarding.

There is an obvious and dangerous next step. Once a system records that
something happened eleven times at two-hour intervals, predicting the twelfth is
one small function away, and it would look like the natural payoff. It is the
one thing this layer must not do. A descriptive system that is wrong is
visibly wrong — the history is right there to check. A predictive system that is
wrong is confidently wrong, and it is wrong at exactly the moment an operator
has stopped checking because it has been right for a month.

## Decision

The platform gains an **Occurrence Timeline** that records temporal history and
describes it. It never predicts.

```
Reality → Collectors → Observations → Evidence → Verification → Knowledge
        → Operational Integrity   (expected vs current)
        → Experience              (what is normal)
        → Occurrence Timeline     (when things happened)
```

### Four concepts

| Entity | Prefix | What it is |
|---|---|---|
| **Occurrence** | `OCC` | One thing that happened, at one time |
| **Occurrence Series** | `SERIES` | Every occurrence of one kind, for one target |
| **Pattern** | `PAT` | A recognised temporal shape in a series |
| **Timeline** | `TL` | An ordered view across kinds |

All four are immutable. New observations create newer records.

### Time is two things, not one

Every occurrence carries both `occurred_at` and `recorded_at`. They are
deliberately separate: the first is when the thing happened, the second is when
the platform noticed.

Collapsing them would place every late-arriving observation at the moment it was
processed rather than the moment it occurred, which quietly corrupts exactly the
ordering the timeline exists to provide.

### First-class temporal concepts

Frequency, intervals, first seen, last seen, recurrence, and ordering are
recorded rather than recomputed ad hoc:

- **first seen / last seen** — the boundaries of what has been observed
- **intervals** — the gap between each consecutive pair
- **frequency** — count over the observed span
- **recurrence** — `regular`, `irregular`, `single`, or `unknown`
- **ordering** — by `occurred_at`, tiebroken by identifier

The tiebreak is required, not cosmetic. Occurrences frequently share an instant,
and without a deterministic secondary sort two reads of the same history would
disagree about their order — which makes a timeline useless for the incident
review it exists for.

### Frequency describes the past

`frequency_per_day` is a count divided by the span actually watched. It is a
statement about a period that has ended.

Nothing in this layer treats it as a rate expected to continue, and the schema
records `forward_looking: false` so a consumer cannot mistake it for one.

### Nothing is invented

One occurrence has no interval and no frequency: both are `null`, never `0`. A
mean interval of zero would say everything happened at once, which is a
different and false claim. An empty series reports `null` throughout and
`unknown` recurrence rather than `regular`.

### Patterns describe, they do not promise

The vocabulary is closed: `recurring`, `burst`, `isolated`, `accelerating`,
`decelerating`. Each is a comparison between measured quantities, each carries
the sentence that justifies it, and none has a field in which a forward claim
could be recorded.

**`recurring` means it has recurred, not that it will.** That distinction is the
entire discipline of this layer.

### Integration without a cycle

Temporal context is combined with integrity and behaviour in the *occurrence*
package. Occurrence already reads integrity and experience vocabulary; making
either depend on occurrence would create a cycle and make the older, more
conservative layers depend on the newest one.

The combination is what makes the other layers legible: `DRIFT + UNEXPECTED`
occurring for the first time is a different situation from the same pair
recurring every Tuesday for a month, and only temporal history distinguishes
them.

### Prepared, but inert: frequency weighting

The Experience Engine counts *distinct retained evidence values*, which
under-weights a steady metric relative to a varying one. Occurrence frequency is
the missing input.

It is exposed on every series and surfaced in the temporal context as
`frequency_weighting: not-applied`. Applying it would change how every existing
baseline reads, so this release does not — but a later one can, without a
schema change or a compatibility break. **Experience continues to use distinct
evidence in v0.8.6.**

### Principles

1. Occurrences are immutable and cite their source.
2. `occurred_at` and `recorded_at` are distinct.
3. Series construction is deterministic and order-independent.
4. Timeline ordering is deterministic, tiebroken by identifier.
5. Pattern detection is deterministic and explains itself.
6. No temporal measure is invented; absent means `null`.
7. Frequency describes the observed span only.
8. No pattern makes a forward-looking claim.
9. Confidence is an engineering heuristic with explicit factors and weights.
10. Nothing here modifies evidence, knowledge, or the declared model.
11. Nothing here remediates.
12. Occurrence depends on integrity and experience; neither depends on it.

## Rejected Alternatives

**Prediction of the next occurrence.** The obvious payoff and the one thing that
would break the layer. A predicted time cannot be checked against evidence until
after the fact, and a system that is confidently wrong at 3am is worse than one
that says nothing.

**Forecasting a rate.** Presenting `frequency_per_day` as a rate expected to
continue converts a description into a promise using the same number, which is
why the schema marks it `forward_looking: false`.

**Probabilistic or Markov models of recurrence.** They would produce better
descriptions of regularity and would make every output unexplainable by hand.
The whole value here is that an operator can recompute any figure from the
occurrences.

**Anomaly detection on intervals.** "This gap is unusual" is an Experience
question, answered by that layer against a baseline. Duplicating it here would
give two components separate opinions about the same thing.

**Autonomous reasoning over the timeline.** An agent that reads history and
decides what it means is a different system with a different risk profile.
This layer reports; humans and later layers interpret.

**Storing occurrences inside the evidence store.** Convenient, and it would
make evidence mutable in practice: deriving occurrences would write into the
store that must never change.

**Recomputing temporal facts on demand instead of recording them.** Cheaper in
storage and it makes every answer depend on which records happen to survive
retention. Occurrences are recorded so history stays answerable.

## Consequences

**Positive.** The platform can answer "has this happened before, and how often?"
with a cited, recomputable answer. Integrity and experience findings gain a
third axis that distinguishes a first occurrence from a repeat. A shared
immutable-store base now exists, so storage correctness lives in one place
rather than four.

**Negative.** Occurrence records accumulate faster than any other kind, and
retention remains undefined across every store. Deriving occurrences reads the
whole evidence set for a target, so cost grows with history. A fourth record
family adds four more prefixes to keep straight.

**Accepted risks.**

- **Pattern thresholds are conventions.** A 25% interval-spread regularity
  boundary and a 5× burst-gap multiple are engineering choices, named as
  constants so they are reviewable, not statistical findings.
- **Coverage is only as broad as collection.** Things nothing observes generate
  no occurrences, and their absence from a timeline is not evidence they did not
  happen.
- **Three stores still duplicate the write path.** This release stops the growth
  and provides the shared base; migrating evidence, integrity, and experience
  onto it is deferred rather than forgotten.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [ADR-0004: Immutable Knowledge Timeline](ADR-0004-immutable-knowledge-timeline.md)
- [ADR-0007: Operational Integrity Engine](ADR-0007-operational-integrity-engine.md)
- [ADR-0008: Experience Engine](ADR-0008-experience-engine.md)
- [Occurrence timeline overview](../occurrence/overview.md)
