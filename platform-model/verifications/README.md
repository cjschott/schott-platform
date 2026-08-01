# Verification Records

Read-only results of comparing declared intent against collected evidence.

**This directory is empty of records, and that is correct.** Verification consumes evidence, and no evidence has been collected yet.

## Purpose

A verification record answers one question: *did evidence support what the model declared, at the moment it was evaluated?*

It does **not** answer whether anything is working now. Operational health is not modeled, because answering it requires live telemetry the platform does not have.

## File Naming

```text
ver-0001-<short-slug>.yaml
```

## Stable IDs

`VER-0001`, four digits, never reused.

## Declared vs Observed vs Inferred

Verification provenance is always `inferred`, with `derived_from` naming the evidence it rests on. A verification result is a *conclusion*, not an observation — conflating the two would let a derived judgement be mistaken for something someone saw.

## Lifecycle vs Verification State

These are different axes and must not be read as one:

| | Question | Example |
|---|---|---|
| Entity `lifecycle` | How mature is the record? | `verified`, `managed` |
| `verification_state` | Did evidence support it? | `drift`, `pending` |

An entity whose lifecycle is `verified` can have a later verification in `drift`. That is not a contradiction: the entity matured, and something changed since.

## Interpretation Rules

Each of these has a plausible-sounding wrong reading, which is why they are stated explicitly:

- **Mismatch does not mean the model is wrong.** It means the two disagree. Which side is stale is a human judgment.
- **Missing evidence is not drift.** "We did not look" and "we looked and it differs" are different facts.
- **Collection failure is not service failure.** A failed connection means the platform could not observe.
- **Stale evidence cannot yield `verified`.** The honest result is `stale_evidence`.
- **`unsupported` is not a pass.** A rule that could not evaluate produced no information.

## No Remediation

`recommended_action` is advisory prose. Nothing here is executed. Validation rejects executable action fields, so the layer cannot grow a remediation path by accident.

Verification records never rewrite canonical entity files, and drift never automatically rewrites entity lifecycle. That separation prevents a transient collection failure from cascading into model-wide maturity downgrades.

## Validation

```bash
python3 tools/platform_model/validate_evidence.py --root platform-model
```

## Example

Synthetic, non-secret:

```yaml
id: VER-0001
type: verification
target: HOST-0001
rule: DRIFT-0001
evaluated_at: 2026-08-01T09:05:00-05:00
evidence:
  - EVID-0001
state: verified
result: match
severity: information
declared_value: ROLE-0001
observed_value: ROLE-0001
explanation: Declared platform role matched the attested role.
recommended_action: none
provenance:
  class: inferred
  derived_from:
    - EVID-0001
approval_required: false
```

## What Does Not Exist Yet

- No evaluation engine. These schemas define the output shape of a future read-only evaluator.
- No automatic remediation.
