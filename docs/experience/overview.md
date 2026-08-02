# Experience Engine

The platform already answers **"what is true?"** — that is evidence.

This engine answers a different question: **"what is normal?"**

Those are deliberately not the same. 98% CPU is a fact; whether it is alarming
depends entirely on whether this host usually sits at 27% or usually sits at 95%.

## What it is not

- **It does not predict.** There is no forecast, no model, no learning.
- **It does not replace evidence.** Delete every profile and no fact is lost.
- **It does not modify knowledge.** It reads; it never writes back.
- **It does not act.** Nothing here remediates, corrects, or recovers.

Everything is standard-library arithmetic over observations that already
happened. A static test forbids importing a numeric or ML library at all.

## Three entities

| Entity | Prefix | What it holds |
|---|---|---|
| Experience Profile | `EXP-000001` | Statistics for one metric over one window |
| Experience Window | `WINDOW-000001` | The bounded span a profile summarizes |
| Operational Baseline | `BASE-000001` | What is typical, from one or more windows |

All three are immutable. New observations create newer records — there is no
update method and no delete method.

## Windows

Rolling: `24h`, `7d`, `30d`, or `custom`.

A custom window requires an explicit duration. No default is assumed, because an
invented span presented as a chosen one makes every profile built on it quietly
wrong.

Windows resolve from an explicit `now` rather than the clock, so the same query
run twice summarizes the same span.

## Statistics

Every profile reports `window_start`, `window_end`, `sample_count`, `minimum`,
`maximum`, `mean`, `median`, `standard_deviation`, and `trend`.

Standard deviation is the **population** form — these are complete observations
of a window, not a sample of a larger set, and the population form is defined
for a single value where the sample form is not.

**Nothing is invented.** With no samples every statistic is `null`, never `0`. A
mean of zero and no mean at all are different claims, and only one of them is
ever true of an unobserved metric.

## Trends

`stable`, `increasing`, `decreasing`, `volatile`, `unknown`.

Classification counts **direction reversals**, gated by amplitude:

- Fewer than three samples → `unknown`. Two points make a line through noise.
- All samples identical, or spread within 5% of the mean → `stable`.
- Direction reverses on more than half the steps → `volatile`.
- Otherwise the halves' means are compared → `increasing` or `decreasing`.

Reversals rather than raw spread, because a clean ramp from 1 to 100 has an
enormous spread and is perfectly directional — judging by spread alone would call
every steady climb "volatile" and bury exactly the trend worth seeing. Amplitude
then gates it, so a metric wobbling between 26% and 28% reads `stable` rather
than reversing on every step into `volatile`.

## Baselines

A baseline says what has been **typical**. It never says what is **correct**.

```
CPU  current 29%  typical 27%  difference +2%   →  EXPECTED
CPU  current 98%  typical 27%  difference +71%  →  UNEXPECTED
```

`UNEXPECTED` is **not** drift. It is a statement about operational history, not
a fault, and frequently reflects an intended change.

Typical is the sample-count-weighted median of the contributing profiles —
median rather than mean, so a single spike does not move what "typical" means.
Tolerance is three standard deviations with a floor of 10% of the typical value;
without the floor a perfectly steady metric would have zero tolerance and every
reading would be unexpected the moment it moved.

**Baselines are never replaced automatically.** A newer baseline is a new
record; which one represents normal is a human decision.

## The four behavioural states

| Status | Meaning |
|---|---|
| `EXPECTED` | Within operational history |
| `UNEXPECTED` | Differs significantly from operational history |
| `UNKNOWN` | No baseline, or no observations to compare against |
| `INSUFFICIENT_EVIDENCE` | Fewer than three samples — too thin to characterise normal |

The last two carry the weight:

- **Missing observations are `UNKNOWN`, never `UNEXPECTED`.** Never having
  watched something is not evidence that it is misbehaving.
- **A low sample count is `INSUFFICIENT_EVIDENCE`, never `UNEXPECTED`.** Two
  readings cannot establish what normal looks like.
- **`unknown` stays unknown.** It is never resolved into something more definite
  for tidiness.

## Confidence

Four factors, weights totalling exactly `1.0`:

| Factor | Weight | Measures |
|---|---|---|
| `coverage` | 0.30 | How much of the window contains observations |
| `sample_quality` | 0.30 | How many samples the statistics rest on |
| `window_size` | 0.20 | Whether the window is long enough to characterise normal |
| `data_age` | 0.20 | How recent the newest observation is |

Every result carries factors, weights, per-factor contributions, and a written
reason per factor. **Confidence is an engineering heuristic, not a probability.**
It answers "how much history is this built on?", not "how likely is this right?".

## Integration with Operational Integrity

Two independent axes. `MATCH` compares against a snapshot; `EXPECTED` compares
against operational history. **`EXPECTED` is not equivalent to `MATCH`**, and
both may hold at once.

| Integrity | Behaviour | Reading | Priority |
|---|---|---|---|
| `MATCH` | `EXPECTED` | Configuration and behaviour both as known | none |
| `MATCH` | `UNEXPECTED` | Config unchanged, behaviour is not — something changed underneath | investigate |
| `DRIFT` | `EXPECTED` | Config changed, behaviour normal — intentional change likely | review |
| `DRIFT` | `UNEXPECTED` | Both disagree with what is known | high |

An `UNKNOWN` or thin behavioural reading never escalates on its own. Escalating
on an absence of history would page someone for not having watched.

Priorities are advisory labels. Nothing triggers on them.

## Usage

Both roots are explicit and never defaulted.

```bash
python3 -m tools.experience.cli build \
  --target HOST-0001 --metric cpu_utilization --window 24h \
  --evidence-root /srv/schott-platform/observations \
  --store-root /srv/schott-platform/experience

python3 -m tools.experience.cli summarize --target HOST-0001 --metric cpu_utilization ...
python3 -m tools.experience.cli compare  --target HOST-0001 --current-value 29 ...
python3 -m tools.experience.cli explain  --target HOST-0001 --current-value 29 ...
```

`explain` shows every number and the reasoning behind it. Records are written
only with `--persist`; without it nothing is stored and no identifier is
consumed, so repeated queries return identical output.

There is no `predict`, `forecast`, `train`, or `delete` command.

## Limitations

- **Evidence deduplication affects sample counts.** The observation layer
  collapses identical repeated content into a single record with a refresh
  event, so a metric reading exactly 27% for twelve hours yields **one** evidence
  record rather than twelve. `sample_count` therefore reflects *distinct retained
  observations*, not collection frequency, and a steady metric is under-weighted
  relative to a varying one. Weighting by refresh events is the natural fix and
  is not implemented yet.
- **A consistently broken system looks normal.** Baselines describe what has
  happened, including a fault that has been happening all along.
- **Least useful when newest.** Statistics need history; a new system has none.
- **Tolerance is a convention**, not a claim about any distribution.
- **Coverage is only as broad as collection.** Metrics nothing collects are
  invisible.

## Related

- [ADR-0008: Experience Engine](../decisions/ADR-0008-experience-engine.md)
- [ADR-0007: Operational Integrity Engine](../decisions/ADR-0007-operational-integrity-engine.md)
- [Operational integrity overview](../integrity/overview.md)
- [Observation engine overview](../observation/overview.md)
