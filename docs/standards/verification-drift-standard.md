# Verification and Drift Standard

## Purpose

This standard defines how the platform compares declared intent against collected evidence, and how it reports the difference without acting on it.

Drift detection is where an operational model most easily becomes dangerous. A system that both detects and corrects difference will eventually correct the wrong side — enforcing a stale declaration onto a correctly-changed environment. This standard separates detection from action permanently.

**This sprint creates schemas only. No verification is executed and no collector exists.**

## Scope

Applies to records under `platform-model/verifications/` and rule definitions under `platform-model/drift-rules/`.

## Core Principle

Verification is **read-only**.

It reads declared entities, reads evidence, compares them, and writes a finding. It never modifies a canonical entity file, never changes runtime state, and performs **no remediation**.

## Verification States

- `unknown` — not evaluated
- `pending` — selected for evaluation, awaiting evidence
- `verified` — evidence supported the declaration at evaluation time
- `warning` — a non-blocking concern was found
- `drift` — declared and observed values differ
- `failed` — evaluation itself could not complete
- `unsupported` — the rule cannot be evaluated for this target

## Drift Severity

- `information`
- `low`
- `medium`
- `high`
- `critical`

## Drift Result Types

- `match` — declared and observed agree
- `mismatch` — they disagree
- `missing_observation` — no evidence exists for the compared fact
- `stale_evidence` — evidence exists but is older than the rule permits
- `unsupported` — the rule does not apply to this target
- `collection_failure` — evidence collection did not succeed

These six are deliberately distinct. Collapsing them is the most common way drift reporting becomes untrustworthy.

## Required Fields

| Field | Meaning |
|---|---|
| `id` | Four-digit `VER` identifier |
| `type` | Always `verification` |
| `target` | Entity evaluated |
| `rule` | Drift rule applied |
| `evaluated_at` | RFC 3339 timestamp with offset |
| `evidence` | Supporting evidence ids |
| `state` | Verification state |
| `result` | Drift result type |
| `severity` | Drift severity |
| `declared_value` | What the model says |
| `observed_value` | What the evidence showed |
| `explanation` | Why the result was reached |
| `recommended_action` | Advisory only |
| `provenance` | Class `inferred`, with `derived_from` |
| `approval_required` | Whether a human must review |

## Interpretation Rules

These exist because each has a plausible-sounding wrong reading:

- **Mismatch does not automatically mean the declared model is wrong.** It means the two disagree. The environment may have drifted, or the declaration may be outdated, or the rule may be comparing the wrong thing. Resolving that is a human judgment.

- **Missing evidence is not drift.** "We did not look" and "we looked and it differs" are different facts. Reporting the first as the second manufactures findings that waste review attention and erode trust in the whole layer.

- **Collection failure is not service failure.** A failed SSH connection means the platform could not observe. It does not mean the service is down.

- **Stale evidence cannot produce a `verified` state.** If the supporting evidence is older than the rule permits, the honest result is `stale_evidence`, not a `verified` state resting on an expired observation.

- **Unsupported is not a pass.** A rule that cannot evaluate a target has produced no information, and must not be counted as compliance.

## Approval and Action

- `recommended_action` is **advisory**. It describes what a human might do; it is never executed.
- **Critical findings require human review.** `approval_required` must be true.
- **No remediation is performed by this layer**, at any severity, under any configuration.
- Drift rules may declare `remediation_mode` only as `advisory` or `manual-approval-required`. `automatic` is not an accepted value, and validation rejects it.
- Verification records must not contain fields describing high-impact actions to execute. Validation rejects them.

## Non-Modification Guarantee

**Verification records never rewrite canonical entity files automatically.**

A verification result is a finding about an entity, stored beside it, not a patch applied to it. Entity records change through normal reviewed change control.

Likewise, **runtime drift does not automatically rewrite entity lifecycle**. A drift finding may prompt a review that leads to a lifecycle transition; it never triggers one directly. This prevents a transient collection failure from cascading into model-wide maturity downgrades.

## Secrets

Verification records must redact secrets. `declared_value` and `observed_value` frequently carry configuration, and configuration is where credentials leak.

Where a compared value is sensitive, record its presence or a non-reversible shape indicator rather than the value.

## Time and Freshness

- `evaluated_at` is required with timezone information.
- Every referenced evidence record has its own `collected_at`; verification freshness is bounded by the *oldest* evidence it rests on.
- A verification result must not be presented as current state. Its age is always evaluable, and consumers must qualify findings by age.

**No verification result asserts that the platform is currently healthy.** It asserts that a comparison produced a result at a moment. Operational health is not modeled.

## Compliance

A verification record complies when:

- It carries every required field with a unique four-digit `VER` id.
- Its state, result, and severity are drawn from the approved vocabularies.
- Its target and evidence references resolve.
- A `verified` state rests on at least one non-stale evidence record.
- Its provenance is `inferred` with `derived_from` populated.
- Critical findings set `approval_required`.
- It contains no secret value and no executable action field.
- It has not modified any canonical entity file.
