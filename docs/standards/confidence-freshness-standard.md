# Confidence and Freshness Standard

## Purpose

The platform makes claims about itself. Some of those claims rest on a command that ran a minute ago; others rest on a human who remembered something in April. Presenting both with the same authority would be dishonest, and treating the second as worthless would discard real information.

This standard defines how the platform expresses *how much a claim should be trusted* — as an explainable score with visible inputs, not an opaque number.

## Scope

Applies to `tools/observation/confidence.py` and to every consumer that reports a confidence or freshness value: verification records, drift assessments, knowledge events, and derived knowledge state.

Out of scope: deciding what to do about low confidence. That is an operator judgement, and this standard deliberately stops short of it.

## Confidence Is a Heuristic, Not a Probability

**Confidence is an engineering heuristic. It is not a probability, and it must never be presented as one.**

A confidence of `0.72` does not mean there is a 72% chance the claim is true. It means the weighted factors below produced `0.72`, and the factors are visible so a human can decide whether they agree. There is no calibration data behind these numbers and no claim of statistical validity.

This matters because a number between zero and one invites probabilistic reading. Any interface presenting confidence must present the factor breakdown alongside it, so the score is read as "here is the reasoning" rather than "here is the likelihood".

## Factors

Five factors, each bounded `0.0` through `1.0`. A value outside that range is an error, not a clamped input — silently clamping hides the bug that produced it.

- `source_reliability` — how much the source type warrants trust on its own. A command executed against the target outranks a human recollection. This is a property of the *source*, not of the observation.
- `freshness` — how recently the supporting evidence was collected, relative to its policy maximum age. Derived from the freshness assessment below.
- `verification` — whether an independent check confirmed the claim. Unverified is `0.0`; that is not a penalty, it is an accurate statement that nothing has checked.
- `source_agreement` — whether independent sources agree. A single source scores moderately: one source cannot corroborate itself. Contradiction scores low.
- `completeness` — whether the expected facts are all present, or the observation is partial.

## Formula

Overall confidence is a **weighted arithmetic mean** with fixed, documented weights:

| Factor | Weight |
|---|---|
| `source_reliability` | 0.25 |
| `freshness` | 0.25 |
| `verification` | 0.25 |
| `source_agreement` | 0.15 |
| `completeness` | 0.10 |

The weights total exactly `1.0`, which is asserted in both the standard and the test suite. There are no hidden factors, no adjustment terms, and no conditional reweighting.

```
overall = Σ (factor_value × factor_weight)
```

A weighted mean was chosen over anything more sophisticated because it is explainable to a human in one sentence and because a more elaborate model would imply precision the inputs do not support. Every factor's contribution is `value × weight`, and the explanation records both.

A consequence worth stating plainly: a claim supported only by human attestation, with nothing verifying it, cannot reach the top of the scale. With `verification` at `0.0` and `source_agreement` moderate, the arithmetic caps out well below `1.0`. That is the intended behaviour — a person saying something is true is evidence, not proof.

## Freshness States

Four states, and no others:

- `current` — the newest supporting evidence is well within its policy maximum age.
- `aging` — past a warning threshold but still within the maximum.
- `stale` — older than the policy maximum age.
- `unknown` — no policy is defined, or there is no supporting evidence to age.

**Knowledge age** is elapsed time from the newest supporting evidence:

```
knowledge_age_seconds = generated_at - newest_supporting_evidence.collected_at
```

It is reported in seconds against the newest supporting record, because the oldest record in a set says nothing useful about how current the overall picture is.

## The Null Policy Rule

**Evidence with no freshness policy produces `freshness: unknown` and `review_required: true`.**

The platform must not invent a maximum age. Choosing a default silently converts an unanswered configuration question into a confident-looking assessment, and the resulting `current` or `stale` label is fabricated. Surfacing `unknown` and asking for review is the honest outcome, and it creates pressure to define the policy rather than hiding its absence.

The same rule applies when there is no supporting evidence at all: the freshness of nothing is `unknown`, never `stale`. Stale means "we looked and it was long ago"; unknown means "we have not looked".

## Compliance

An implementation complies when:

- every factor value is bounded `0.0` through `1.0`, and out-of-range input raises rather than clamps
- the five factor names match this standard exactly
- the weights match the table above and total `1.0`
- the result is deterministic for identical inputs
- every reported confidence carries an explanation listing each factor, its value, and its weight
- freshness is one of `current`, `aging`, `stale`, `unknown`
- a null freshness policy produces `unknown` with `review_required: true`, never a default maximum age
- absent evidence produces `unknown`, never `stale`
- stale evidence lowers the freshness factor and cannot support a `verified` state
- no interface presents confidence as a probability

Enforced by `tests/test-knowledge-orchestrator.sh` and asserted structurally by `tests/test-docs-static.sh`.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Knowledge Event Standard](knowledge-event-standard.md)
- [Verification and Drift Standard](verification-drift-standard.md)
