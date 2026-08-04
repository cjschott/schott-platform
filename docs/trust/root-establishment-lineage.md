# Root Establishment Lineage

The record of how an Operator Root Authority came to exist. Governed by
[ADR-0014](../decisions/ADR-0014-root-establishment-lineage.md), which refines
[ADR-0011](../decisions/ADR-0011-trust-plane.md).

> **Nothing here is implemented.** No model class exists, no store write occurs,
> and no lineage record has been persisted for the production root. This is the
> contract ENG-0001 implements test-first.

## The distinction this record exists to hold

A **subject decision lineage** records what the platform decided about a
subject, on evidence, at a moment. Every state in it was produced by a
`TrustDecision` that can be re-examined.

A **root establishment lineage** records that an authority was established
**outside** the platform, by a human ceremony. Nothing decided it. No authority
approved it. There is no decision to point at, and fabricating one would record
an approval that never happened — by an authority that is forbidden from
approving itself.

One model cannot honestly describe both. `TrustLineage` describes the first.
`RootAuthorityLineage` describes the second.

## Discrimination

Every lineage record carries `lineage_type` as a constant, non-empty
discriminator. **A reader resolves `lineage_type` before interpreting any other
field.**

| `lineage_type` | Model | Decision identifiers |
|---|---|---|
| `subject-decision` | `TrustLineage` | required, exactly as released |
| `root-establishment` | `RootAuthorityLineage` | **not fields on the model** |

An unrecognised, empty, or missing `lineage_type` is **refused**. Unknown fails
closed here as everywhere in this plane.

Both types share the `TLIN-` identifier space and the `lineages/` directory.
Storage is unchanged; only interpretation is discriminated.

## `RootAuthorityLineage` fields

| Field | Type | Required | Value for the ceremony |
|---|---|---|---|
| `lineage_id` | `^TLIN-[0-9]{6}$` | yes | `TLIN-000001` |
| `version` | integer ≥ 1 | yes | `1` |
| `lineage_type` | constant | yes | `root-establishment` |
| `authority_id` | `^TAUTH-[0-9]{6}$` | yes | `TAUTH-000001` |
| `subject_type` | string | yes | `operator-root` |
| `establishment_origin` | non-empty string | yes | `external-operator-ceremony` |
| `evidence_reference_ids` | tuple of `^TEVID-[0-9]{6}$` | yes, ≥ 1 | `TEVID-000001`…`TEVID-000005` |
| `establishment_audit_id` | `^TAUDIT-[0-9]{6}$` | yes | `TAUDIT-000001` |
| `current_state` | `TrustState` | yes | `trusted` |
| `established_at` | timezone-aware datetime | yes | the authority's `created_at` |
| `recorded_at` | timezone-aware datetime | yes | when the record was written |
| `terminated` | boolean | no, default `false` | `false` |

Stored as `lineages/TLIN-000001-v0001.yaml`, matching the released
`LINEAGE_VERSION_ID` pattern. The identifier is the one **already allocated** by
the ceremony. **No second `TLIN` is allocated.**

### Fields that must not exist

`first_decision_id` · `current_decision_id` · `prior_decision_ids` ·
`root_authority_id` · `approved_by` · `approval_source` · `supersedes` ·
`trust_score` · `score` · `threshold` · `command` · any credential field.

These are **absent from the model**, not empty on it. No code path can populate
them, and a stored record carrying any of them is malformed rather than
tolerated.

`root_authority_id` is omitted deliberately. A root naming itself as its own
terminating authority reads as self-approval to anyone who does not already
know it is not. `authority_id` says what the record is about without making a
claim about who approved it — because nobody in this platform did.

### Invariants

1. **No decision is referenced, and none is fabricated.**
   No `TDEC` is created, read, or implied.
2. **No self-approval is expressed.** The record states an external origin, not
   an approval.
3. **Immutable and append-only.** Write-once via `os.link`; no update method, no
   delete method.
4. **Existing records are never rewritten.** Writing this lineage changes no
   authority, evidence, or audit record.
5. **Advancing is undefined in this release.** Superseding the root is not
   implemented; a version-2 path is not invented here.

## What writes it

`declare_root_authority()` constructs and writes the lineage using the lineage
identifier it has **already allocated** for the authority, within the same call
that writes the authority and audit records.

Ordering: evidence, then lineage, then authority, then audit. The lineage exists
before the authority that names it, so a partially written store never contains
an authority pointing at a lineage that was never written.

`TrustLineage` construction and `declare_decision` are **not touched**.

## The existing production store

`TAUTH-000001` exists and cannot be re-declared — a second active root is
refused, correctly. **Fixing the write path does not retroactively create
`TLIN-000001`.**

Backfill is a **separate, explicitly operator-approved, append-only action**.
ENG-0001 specifies it and does not perform it. It must:

- write `TLIN-000001-v0001` and nothing else;
- leave `TAUTH-000001` and `TAUDIT-000001` **byte-identical**, verified by
  digest before and after;
- emit its **own new** audit event, never amending `TAUDIT-000001`;
- be refused if a lineage record for `TLIN-000001` already exists;
- record the operator decision and reason.

Amending the ceremony's audit event is **forbidden**. That event records what
happened at the ceremony. A later repair is a later event.

## Store validation

`validate-store` gains one rule: **every authority's `lineage_id` must resolve
to a `root-establishment` lineage record.**

Until the production backfill is approved and performed, this reports the
existing store's missing lineage as a finding. That is accurate — the record is
genuinely absent. Validation reports; it repairs nothing.

## Related

- [ADR-0014: The Root Establishment Lineage](../decisions/ADR-0014-root-establishment-lineage.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Root authority operations](root-authority-operations.md)
- [Trust states](trust-states.md)
- [Trust Plane runtime overview](runtime-overview.md)
