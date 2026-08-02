# Occurrence Timeline

The platform already answers *what is true* (evidence), *what we believe*
(knowledge), *is this still the system we confirmed* (integrity), and *is this
normal* (experience).

This layer answers: **has this happened before?**

That is the question an operator asks first during an incident, and until now
the platform could not answer it — the information existed, scattered across
evidence timestamps, in a form nobody could read without reconstructing it by
hand.

## What it never does

**It does not predict.** No forecasting, no model, no probability, no
autonomous reasoning. Every number is recomputable by hand from the occurrences
it summarizes.

Once a system records that something happened eleven times at two-hour
intervals, predicting the twelfth is one small function away — and it is the one
thing this layer must not do. A descriptive system that is wrong is visibly
wrong, because the history is right there to check. A predictive system that is
wrong is confidently wrong, at exactly the moment an operator has stopped
checking.

## Four entities

| Entity | Prefix | What it holds |
|---|---|---|
| Occurrence | `OCC-000001` | One thing that happened, at one time |
| Occurrence Series | `SERIES-000001` | Every occurrence of one kind, for one target |
| Pattern | `PAT-000001` | A recognised temporal shape |
| Timeline | `TL-000001` | An ordered view across kinds |

All four are immutable. There is no update method and no delete method.

## Time is two things

Every occurrence carries **both** `occurred_at` and `recorded_at` — when the
thing happened, and when the platform noticed.

Collapsing them would place a late-arriving observation at the moment it was
processed rather than the moment it occurred, quietly corrupting the ordering
the timeline exists to provide.

## First-class temporal concepts

| Concept | Meaning |
|---|---|
| **first seen** | The earliest observed occurrence |
| **last seen** | The most recent observed occurrence |
| **interval** | The gap between each consecutive pair |
| **frequency** | Count over the observed span |
| **recurrence** | `regular`, `irregular`, `single`, or `unknown` |
| **ordering** | By `occurred_at`, tiebroken by identifier |

The tiebreak is required, not cosmetic. Occurrences frequently share an instant,
and without a deterministic secondary sort two reads of the same history would
disagree — which makes a timeline useless for incident review.

## Recurrence

Classified by the **coefficient of variation**: interval spread relative to the
mean gap, so a series of daily events and a series of yearly events are judged
on consistency rather than absolute size.

- Spread within 25% of the mean gap → `regular`
- Spread above it → `irregular`
- Exactly one occurrence → `single` (a single event has no spacing)
- No occurrences → `unknown`

`single` and `unknown` are real answers, not fallbacks. Reporting either as
`regular` would claim a rhythm nobody observed.

## Nothing is invented

**One occurrence has no interval and no frequency.** Both are `null`, never
`0` — a mean interval of zero would say everything happened at once, which is a
different and false claim.

An empty series reports `null` for every temporal measure and `unknown`
recurrence.

## Frequency describes the past

`frequency_per_day` is a count divided by the span actually watched. It is a
statement about a period that has **ended**.

Nothing here treats it as a rate expected to continue, and the schema records
`forward_looking: false` so a consumer cannot mistake it for one.

## Patterns

Closed vocabulary, each a comparison between measured quantities, each carrying
the sentence that justifies it:

| Pattern | Meaning |
|---|---|
| `recurring` | Evenly spaced across the observed period |
| `burst` | A long gap followed by clustered occurrences |
| `isolated` | A single occurrence, with nothing before it |
| `accelerating` | Gaps shrank across the observed period |
| `decelerating` | Gaps widened across the observed period |

**`recurring` means it has recurred, not that it will.** That distinction is the
entire discipline of this layer, and the model carries no field in which a
forward claim could be recorded.

An empty series yields no patterns. Inventing one would be the clearest possible
case of describing something nobody observed.

## Confidence

Four factors, weights totalling exactly `1.0`:

| Factor | Weight | Measures |
|---|---|---|
| `occurrence_count` | 0.35 | How many occurrences the summary rests on |
| `observation_span` | 0.25 | How long a period they cover |
| `interval_regularity` | 0.20 | How consistent the gaps are |
| `data_age` | 0.20 | How recent the newest occurrence is |

Every result carries factors, weights, per-factor contributions, and a written
reason. Out-of-range and missing factors raise rather than clamping.

**Confidence is an engineering heuristic, not a probability.** It says how much
history a description rests on — never how likely it is to continue.

## Integration with integrity and experience

Temporal context is combined with the other two axes in this package, because
occurrence reads their vocabulary and neither reads its own. The reverse would
create a cycle and make the older layers depend on the newest.

The combination is what makes the other layers legible:

- `DRIFT + UNEXPECTED`, **first occurrence** — something new; there is no
  history to compare it against
- `DRIFT + UNEXPECTED`, **recurring for a month** — a known, repeating
  condition, which is a very different conversation

Both readings are statements about what has been recorded. Neither says what
happens next.

## Prepared, but inert: frequency weighting

The Experience Engine counts *distinct retained evidence values*, which
under-weights a steady metric relative to a varying one. Occurrence frequency is
the missing input.

It is exposed on every series and reported as `frequency_weighting:
not-applied`. Applying it would change how every existing baseline reads, so
this release does not — but a later one can, without a schema change or a
compatibility break. **Experience continues to use distinct evidence in
v0.8.6.**

## Usage

Both roots are explicit and never defaulted.

```bash
python3 -m tools.occurrence.cli record \
  --target SVC-0001 --kind service-restart \
  --evidence-root /srv/schott-platform/observations \
  --store-root /srv/schott-platform/occurrences

python3 -m tools.occurrence.cli series   --target SVC-0001 --kind service-restart ...
python3 -m tools.occurrence.cli patterns --target SVC-0001 --kind service-restart ...
python3 -m tools.occurrence.cli timeline --target SVC-0001 --kind service-restart ...
```

Records are written only with `--persist`; without it nothing is stored and no
identifier is consumed, so repeated queries return identical output.

There is no `predict`, `forecast`, `update`, or `delete` command.

## Limitations

- **Coverage is only as broad as collection.** Things nothing observes generate
  no occurrences, and their absence from a timeline is not evidence they did not
  happen.
- **Occurrences accumulate faster than any other record kind**, and retention
  remains undefined across every store.
- **Deriving occurrences reads a target's whole evidence set**, so cost grows
  with history.
- **Pattern thresholds are conventions** — a 25% regularity boundary and a 5×
  burst-gap multiple are engineering choices, named as constants so they are
  reviewable, not statistical findings.

## Related

- [ADR-0009: Occurrence Timeline](../decisions/ADR-0009-occurrence-timeline.md)
- [ADR-0008: Experience Engine](../decisions/ADR-0008-experience-engine.md)
- [Experience engine overview](../experience/overview.md)
- [Operational integrity overview](../integrity/overview.md)
