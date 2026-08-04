# ADR-0014: The Root Establishment Lineage

- **Status:** Accepted
- **Date:** 2026-08-04
- **Decision Makers:** Schott Platform Engineering
- **Refines:** [ADR-0011: The Trust Plane](ADR-0011-trust-plane.md)

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved.

> **This ADR defines architecture only. There is no runtime implementation in
> this release** — no new model class, no new store write, no change to
> `declare_root_authority`, and no lineage record is persisted for the existing
> production root. This document is the specification that ENG-0001 implements
> test-first. Where something is undecided, this ADR says so explicitly rather
> than leaving a gap for whoever implements it first.

## Context

The Operator Root Authority ceremony established `TAUTH-000001` and allocated
lineage identifier `TLIN-000001`. No lineage record was written. The identifier
is referenced by both the authority record and the root-declaration audit event,
so the store names a lineage that does not exist as a record.

The obvious repair — construct a `TrustLineage` for the root — is not available,
and the reason is architectural rather than incidental.

`TrustLineage` requires `first_decision_id` and `current_decision_id`, both
matching `^TDEC-[0-9]{6}$`. It is the record of **a subject's chain of trust
decisions**: something the platform decided, about something else, on evidence,
at a moment. Every field it requires exists because a decision produced it.

The Operator Root was not decided. It was **established outside the platform**
by a human ceremony, and the platform recorded that this had happened. There is
no decision to point at, and there must not be one:

- `declare_root_authority` writes no decision, by design.
- `evaluator.py` refuses any decision whose subject is its own actor —
  *"an authority cannot approve itself; something outside must establish it."*

So a `TrustLineage` for the root could only be produced by fabricating a `TDEC`
that records a decision nobody made, by an authority that is forbidden from
making it about itself. That is not a persistence bug being fixed; it is a
false record being manufactured to satisfy a schema.

The defect is therefore not "the lineage write was forgotten." It is that
**one model was asked to describe two different things**, and only one of them
is a decision chain.

## Decision

**A root establishment lineage is a distinct, dedicated record type.**

`RootAuthorityLineage` is introduced as its own immutable model. `TrustLineage`
is not modified, not relaxed, and not made partially optional. Every invariant
it enforces for ordinary subject decision lineages survives exactly as released.

### Why a dedicated model rather than an optional-field variant

Making `first_decision_id` optional on `TrustLineage` would weaken the one
guarantee that makes a subject lineage auditable: that every state it records
was produced by a decision that can be re-examined. A single nullable field
would silently permit a decision-less subject lineage, which is the shape of a
trust record that nobody authorised. The failure mode of the wrong choice here
is not a crash — it is a plausible-looking lineage with nothing behind it.

Two record types, each with total invariants, cannot express that state at all.

### The discriminator

Both models write `lineage_type` as a constant, non-empty discriminator:

| Model | `lineage_type` | Decision fields |
|---|---|---|
| `TrustLineage` | `subject-decision` | required, as released |
| `RootAuthorityLineage` | `root-establishment` | **absent from the model** |

A reader discriminates on `lineage_type` before interpreting any other field.
An unrecognised or missing `lineage_type` is refused, not guessed — an
unreadable lineage fails closed like every other unknown in this plane.

`RootAuthorityLineage` does not merely leave the decision fields empty. **The
fields do not exist on the model**, so no code path can populate them, and a
stored record carrying them is malformed rather than tolerated.

Adding the discriminator to `TrustLineage` rewrites nothing: zero subject
lineages exist in any store. There is no migration, because there is nothing to
migrate.

### `RootAuthorityLineage` contract

| Field | Value | Notes |
|---|---|---|
| `lineage_id` | `TLIN-000001` | the **already allocated** identifier; never re-allocated |
| `version` | `1` | append-only; stored as `TLIN-000001-v0001` |
| `lineage_type` | `root-establishment` | constant discriminator |
| `authority_id` | `TAUTH-000001` | the established authority |
| `subject_type` | `operator-root` | |
| `establishment_origin` | `external-operator-ceremony` | required, non-empty |
| `evidence_reference_ids` | `TEVID-000001` … `TEVID-000005` | the immutable ceremony evidence |
| `establishment_audit_id` | `TAUDIT-000001` | the root-declaration audit event |
| `current_state` | `trusted` | |
| `established_at` | ceremony `created_at` | timezone-aware |
| `recorded_at` | when the record was written | timezone-aware |
| `terminated` | `false` | |

**Deliberately absent, and absent from the model itself:**

`first_decision_id` · `current_decision_id` · `prior_decision_ids` ·
`root_authority_id` · `approved_by` · `approval_source` · any decision, score,
threshold, command, or credential field.

`root_authority_id` is omitted rather than self-referenced. A root pointing at
itself as its own terminating authority is readable as self-approval by anyone
who does not already know it is not. `authority_id` says what the record is
about without making a claim about who approved it, because **nobody in this
platform approved it** — that is the entire point of an external root.

### What this record asserts, and what it does not

It asserts: an external ceremony established this authority, here is the
evidence it produced, here is the audit event that recorded it, and this is the
origin of the chain.

It does not assert: that the platform decided anything, that any authority
approved anything, or that trust was granted by a decision.

### Immutability

The record is append-only and immutable under the existing store semantics:
write-once via `os.link`, no update method, no delete method. Advancing a root
establishment lineage is **not defined in this release** — superseding the root
is not implemented, and inventing a version-2 path for a record that has no
defined reason to advance would be inventing behaviour.

### The existing production store

`TAUTH-000001` already exists and cannot be re-declared: a second active root is
refused, correctly. Fixing `declare_root_authority` therefore repairs future
root establishment and **does not retroactively create `TLIN-000001`** in the
production store.

Backfilling the existing store is a **separate, explicitly operator-approved
append-only action**, specified but not performed by ENG-0001. It must:

- write `TLIN-000001-v0001` and nothing else,
- leave `TAUTH-000001` and `TAUDIT-000001` **byte-identical**,
- emit its own new audit event rather than amending the ceremony's, and
- be refused if a lineage record for `TLIN-000001` already exists.

Amending `TAUDIT-000001` to reference the new record is **forbidden**. The
ceremony's audit event records what happened at the ceremony. A later repair is
a later event.

### Store validation

`validate-store` gains one rule: every authority's `lineage_id` must resolve to
a `root-establishment` lineage record. Until the production backfill is
approved and performed, that rule reports the existing store's missing lineage
as a **finding**, which is accurate — the record is genuinely absent.

This is a reporting change only. Validation repairs nothing, here as everywhere.

## Consequences

**The root's origin becomes a first-class record** rather than a dangling
identifier, and it says truthfully how the authority came to exist.

**Two lineage types must now be read discriminated.** Any consumer that assumed
a lineage record carries decision identifiers must check `lineage_type` first.
There is one such consumer today and no stored subject lineages, so the cost is
paid now rather than after the fabric depends on it.

**The existing production store stays inconsistent until an operator approves
the backfill.** This is deliberate. The alternative — silently writing a record
into a store whose ceremony is closed — would be the platform repairing its own
root without a human, which is the failure this plane exists to prevent.

**Accepted risks.**

- A second lineage model is more surface than one nullable field. Accepted: the
  nullable field permits an unauthorised-looking subject lineage, and this does
  not.
- `validate-store` will report a finding against production until backfill.
  Accepted: an accurate finding is better than a validator that passes because
  it was never told to look.

## Related

- [ADR-0011: The Trust Plane](ADR-0011-trust-plane.md)
- [Root establishment lineage contract](../trust/root-establishment-lineage.md)
- [Root authority operations](../trust/root-authority-operations.md)
- [Operator Root Authority establishment record](../history/0001-operator-root-establishment.md)
- [Runtime sequencing correction](../history/0002-runtime-sequencing-correction.md)
