# Capability Model Standard

## Purpose

This standard defines how the Schott Platform records what it can **intentionally provide**.

A capability is not a service, a host, or a piece of code. It is a stated ability — "the platform can detect drift" — recorded with an honest assessment of how far that ability has actually been built.

The standard exists because capability claims are the easiest thing in a platform to overstate. A directory full of schemas can look like a working evidence pipeline. Naming the ability and separately naming its maturity forces the gap to be visible.

## Scope

Applies to records under `platform-model/capabilities/`.

## Core Principle

**Maturity is a claim about implementation, not about intent.**

A capability that is designed, documented, and schema-complete but has never processed real input is `foundation`, not `operational`. Recording it as operational would make the model assert something the platform cannot do.

## Identifiers

`CAP-0001` through `CAP-9999`. Four digits, never reused, filenames are the bare slug.

## Required Fields

| Field | Meaning |
|---|---|
| `id` | Stable four-digit identifier |
| `type` | Always `capability` |
| `name` | Human-readable name |
| `description` | What the platform can do |
| `lifecycle` | Entity maturity, per the Entity Lifecycle Standard |
| `owner` | Accountable party |
| `maturity` | How far implementation has actually progressed |
| `risk` | Consequence if the capability misbehaves or is trusted wrongly |
| `inputs` | What it consumes |
| `outputs` | What it produces |
| `dependencies` | Capabilities it requires |
| `implemented_by` | Code, services, or model records providing it |
| `validated_by` | Tests or checks proving it works |
| `documented_by` | Governing standards and decisions |
| `approval_required` | Whether use requires human approval |
| `provenance` | Provenance block, per the Operational Metadata Standard |
| `review_required` | Whether the record's claims are unconfirmed |

`lifecycle` and `maturity` are different axes and both are required. Lifecycle describes the *record*; maturity describes the *implementation*.

## Maturity Values

- `planned` — decided, not built. No implementation exists.
- `foundation` — contracts, schemas, or scaffolding exist; nothing has processed real input.
- `partial` — works for some cases or some inputs, with known gaps.
- `operational` — works for its intended scope and is relied upon.
- `optimized` — operational, with performance and reliability deliberately tuned.
- `retired` — no longer provided.

The line between `foundation` and `partial` is whether anything real has flowed through. Schemas and tests alone are `foundation`.

## Risk Values

- `low` — misbehaviour is inconvenient
- `medium` — misbehaviour causes rework or confusion
- `high` — misbehaviour causes wrong operational decisions
- `critical` — misbehaviour risks data loss, outage, or security exposure

Risk is assessed on the consequence of the capability being *wrong or wrongly trusted*, not on how hard it was to build. A capability that produces confident-looking output from unverified input is high risk regardless of its maturity.

## Required Initial Capabilities

| ID | Name |
|---|---|
| `CAP-0001` | Platform Modeling |
| `CAP-0002` | Evidence Collection |
| `CAP-0003` | Verification |
| `CAP-0004` | Drift Detection |
| `CAP-0005` | Knowledge Reasoning |
| `CAP-0006` | LLM Routing |
| `CAP-0007` | Automation Planning |
| `CAP-0008` | Human Approval Workflow |

## Honesty Requirements

- **Do not claim operational maturity for unimplemented capabilities.** This is the single rule the standard exists to enforce.
- A capability whose maturity cannot be justified from committed evidence sets `review_required: true`.
- Where maturity differs from the value suggested at design time, the record must state why.
- `implemented_by` must reference something that exists. An empty implementation list and `operational` maturity are contradictory.
- `validated_by` must reference real checks. A capability nothing tests is not validated, whatever its maturity.

## Compliance

A capability record complies when:

- It carries every required field with a unique four-digit `CAP` identifier.
- Its maturity and risk values are drawn from the approved vocabularies.
- Its maturity is justified by what is actually implemented and validated.
- Its dependencies resolve to existing capabilities.
- It carries a provenance block.
- Unconfirmed claims are flagged `review_required` rather than asserted.
