# ADR-0008: Experience Engine

- **Status:** Accepted
- **Date:** 2026-08-02
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved. The
> gap is deliberate, not an omission.

## Context

The platform can answer *what is true?* Evidence records observations, knowledge
derives current belief, and snapshots preserve a state someone confirmed was
good.

It cannot answer a question an operator asks constantly: **is this normal?**

98% CPU is a fact. Whether it is alarming depends entirely on whether this host
usually sits at 27% or usually sits at 95%, and nothing in the platform records
that. Every alert threshold written without it is a guess dressed as a number.

Answering it requires memory of a different kind. Evidence remembers individual
observations; what is needed is a summary of many observations over time —
operational memory rather than a longer list of facts.

The obvious way to build it is also the trap. Once a system summarizes history,
the temptation is to have it *predict* the next value, *learn* what is normal
online, and *update itself* as behaviour drifts. Each of those turns an
auditable summary into a model nobody can explain, and an unexplainable model is
exactly what an operator cannot act on at three in the morning.

## Decision

The platform gains an **Experience Engine** that summarizes observed history and
does nothing else.

```
Reality → Collectors → Observations → Evidence → Verification → Knowledge
        → Experience Engine → Digital Twin → Integrity Analysis
        → Recovery Planning
```

### Why operational memory differs from evidence

Evidence answers *what did we see, and when*. Each record is a single
observation, immutable and individually citable.

Experience answers *what have we usually seen*. It is a summary over many
records, and it is worth nothing on its own — delete every profile and the
platform loses no facts, only a convenience.

That asymmetry is why this is a separate layer. Evidence must never be shaped by
what is typical, or an unusual-but-true observation would be smoothed away at
the moment it mattered most.

### Why statistics are not knowledge

A mean is not a fact about the platform. It is a fact about a set of
measurements.

"CPU averages 27%" says nothing about whether 27% is correct, healthy, or
intended. It says only that 27% is what has been seen. **Statistics are not
knowledge** — they describe the observations, not the system — and the engine
labels its own output as such in every record it produces.

### Why expected behaviour is not truth

`EXPECTED` means a value sits within its operational history. It does not mean
the value is right.

A system that has been failing the same way for a month has a perfectly
consistent history, and every reading will be `EXPECTED`. Conversely, a system
that has just been correctly upgraded will read `UNEXPECTED` for a while and be
entirely healthy.

This is why `EXPECTED` is deliberately *not* equivalent to `MATCH`. `MATCH`
compares against a snapshot someone confirmed was good; `EXPECTED` compares
against whatever has been happening. Both axes are reported, and neither implies
the other.

### Why machine learning is intentionally excluded

No neural networks, no forecasting, no anomaly models, no online learning. Not
because they would not work, but because of what they would cost here:

- **Explainability.** Every number this engine reports can be recomputed by
  hand from the samples. A model's output cannot, and "the model flagged it" is
  not something an operator can act on.
- **Determinism.** The same history must always produce the same summary.
  Training introduces order-dependence and, usually, randomness.
- **Auditability.** A statistic can be checked against the evidence it came
  from. A learned weight cannot.
- **Failure mode.** A wrong statistic is visibly wrong. A wrong model is
  confidently wrong, and confident wrongness is what an operational platform can
  least afford.

The engine is a calculator over observations. It uses the standard library and
nothing else, and a static test forbids importing a numeric or ML library at
all.

### Entities

| Entity | Prefix | What it is |
|---|---|---|
| Experience Profile | `EXP` | Statistics for one metric over one window |
| Experience Window | `WINDOW` | The bounded span a profile summarizes |
| Operational Baseline | `BASE` | What is typical, from one or more windows |

All three are immutable. New observations create newer records; nothing is ever
updated or deleted.

### Rules that keep it honest

1. **Missing observations are `UNKNOWN`, never `UNEXPECTED`.** Never having
   watched is not evidence of misbehaviour.
2. **A low sample count is `INSUFFICIENT_EVIDENCE`, never `UNEXPECTED`.** Two
   readings cannot establish normal.
3. **`UNKNOWN` stays `UNKNOWN`.** It is never resolved to something more
   definite for tidiness.
4. **Never invent a statistic.** No samples means null, not zero.
5. **Baselines are never replaced automatically.**
6. **Nothing is predicted.** Only observed history is summarized.

## Rejected Alternatives

**Predictive AI.** Forecasting the next value would make the engine far more
impressive and far less useful: a prediction cannot be checked against evidence,
and a wrong prediction is indistinguishable from a right one until after the
fact. The platform's job is to describe what happened.

**Online learning.** Continuously updating an internal model would make the
engine's behaviour depend on the order observations arrived in, so two platforms
fed identical data could disagree. Determinism is worth more than adaptivity
here.

**Automatic baseline updates.** Refreshing the baseline whenever behaviour
changes means it always describes current behaviour — at which point nothing can
ever be unexpected, and the whole mechanism becomes decorative. This is the same
failure ADR-0007 rejects for expected-state files.

**LLM-generated expectations.** Asking a model what a normal CPU figure looks
like produces a plausible number with no connection to this platform. A
confident, unauditable, entirely invented baseline is worse than none.

**Automatic anomaly correction.** Acting on `UNEXPECTED` would mean acting on a
statistical observation about history, which frequently reflects an intended
change. The engine recommends nothing and executes nothing.

**Storing raw samples in the profile.** Convenient for recomputation, and it
would duplicate evidence into a second, less protected store. Profiles reference
what they summarized; evidence remains the record.

## Consequences

**Positive.** The platform can distinguish "unusual" from "wrong". Every number
is recomputable by hand from evidence. Integrity findings gain a second,
independent axis, so `DRIFT + EXPECTED` (probably an intended change) reads
differently from `DRIFT + UNEXPECTED` (investigate now).

**Negative.** Profiles and baselines accumulate; retention is deferred as it is
for evidence. Baselines describe a period that may include a fault, so a system
that has been broken consistently looks normal — the documentation says so
plainly. Statistics require history, so the engine is least useful when a system
is newest.

**Accepted risks.**

- **Evidence deduplication affects sample counts.** The observation layer
  collapses identical repeated content into one record with a refresh event, so
  a metric reading exactly 27% for twelve hours yields one evidence record, not
  twelve. `sample_count` therefore reflects *distinct retained observations*,
  not collection frequency, and a steady metric is under-weighted relative to a
  varying one. Weighting by refresh events is the natural fix and is deferred
  rather than hidden.
- **Tolerance is a convention.** Three standard deviations with a 10% floor is a
  defensible engineering choice, not a claim about any distribution.
- **A third immutable store now exists.** The evidence, integrity, and
  experience stores share a write path by duplication rather than by a common
  module. Three copies is past the point where that is the cheaper risk;
  consolidating into one reusable immutable-store module is recorded follow-up
  work.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [ADR-0004: Immutable Knowledge Timeline](ADR-0004-immutable-knowledge-timeline.md)
- [ADR-0007: Operational Integrity Engine](ADR-0007-operational-integrity-engine.md)
- [Experience engine overview](../experience/overview.md)
