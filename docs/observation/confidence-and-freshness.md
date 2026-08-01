# Confidence and Freshness

How the platform says *how much* a claim should be trusted.

The normative rules live in the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md).
This document explains the reasoning and shows the output.

## Confidence is not a probability

`0.72` does not mean a 72% chance of being true. It means the five weighted
factors produced `0.72`, and the factors are visible so a human can decide
whether they agree.

There is no calibration data behind these numbers. Any interface that shows a
confidence score must show the breakdown with it — otherwise a number between
zero and one will be read as a likelihood, which it is not.

## The five factors

| Factor | Weight | What it measures |
|---|---|---|
| `source_reliability` | 0.25 | How much the source type warrants trust on its own |
| `freshness` | 0.25 | How recently the evidence was collected, against policy |
| `verification` | 0.25 | Whether an independent check confirmed it |
| `source_agreement` | 0.15 | Whether independent sources agree |
| `completeness` | 0.10 | Whether the expected facts are all present |

Weights total exactly `1.0`, asserted in the standard, the code, and the tests.

```
overall = Σ (factor_value × factor_weight)
```

A weighted mean beats anything more elaborate here because it can be explained
in a sentence. A model with more machinery would imply a precision these
inputs do not have.

## Consequences worth stating

**Human attestation alone cannot reach the top of the scale.** With
`verification` at `0.0` and agreement moderate, the arithmetic caps out around
`0.55`. That is intended: a person saying something is true is evidence, not
proof.

**A single source scores `0.6` for agreement, not `1.0`.** One source cannot
corroborate itself, and full marks would let one collector's bug look like
consensus.

**Out-of-range values raise rather than clamp.** Clamping hides the bug that
produced the bad value and turns nonsense into a plausible-looking score.

## Freshness

Four states: `current`, `aging`, `stale`, `unknown`.

```
knowledge_age_seconds = generated_at - newest_supporting_evidence.collected_at
```

Measured against the *newest* supporting record, because the oldest one says
nothing useful about how current the overall picture is.

## The null policy rule

**No freshness policy produces `unknown` and `review_required: true`.**

The platform never invents a maximum age. A default silently converts an
unanswered configuration question into a confident-looking assessment, and the
resulting `current` or `stale` label is fabricated. Surfacing `unknown` is
honest and creates pressure to define the policy rather than hiding its
absence.

The same applies to absent evidence: the freshness of nothing is `unknown`,
never `stale`. Stale means "we looked, and it was long ago".

## Example output

```json
{
  "overall": 0.605,
  "factors": {
    "completeness": 1.0,
    "freshness": 1.0,
    "source_agreement": 0.6,
    "source_reliability": 0.9,
    "verification": 0.0
  },
  "weights": {
    "completeness": 0.1,
    "freshness": 0.25,
    "source_agreement": 0.15,
    "source_reliability": 0.25,
    "verification": 0.25
  },
  "contributions": {
    "completeness": 0.1,
    "freshness": 0.25,
    "source_agreement": 0.09,
    "source_reliability": 0.225,
    "verification": 0.0
  },
  "interpretation": "engineering heuristic, not a probability"
}
```

The `contributions` block is what makes the score reviewable: it shows exactly
where the number came from, and here it shows the score is held down by
nothing having verified the claim.

## Related

- [Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
- [Knowledge state](knowledge-state.md)
- [Observation engine overview](overview.md)
