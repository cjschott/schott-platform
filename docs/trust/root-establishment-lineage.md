# Root Establishment Lineage

The record of how an Operator Root Authority came to exist. Governed by
[ADR-0014](../decisions/ADR-0014-root-establishment-lineage.md), which refines
[ADR-0011](../decisions/ADR-0011-trust-plane.md).

> **Implementation status (ENG-0001, merged — not released).** The
> `RootAuthorityLineage` model, the discriminated read path, the
> `declare_root_authority` write, and the `validate-store` rule are implemented
> and covered by `tests/test-trust-runtime.sh`.
>
> **No lineage record has been persisted for the existing production root.**
> `TAUTH-000001` cannot be re-declared, so the fix repairs future root
> establishment only. `validate-store` now reports the production store's
> missing lineage as an accurate finding. The backfill remains constrained and
> **unauthorised** — see [the existing production store](#the-existing-production-store).

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

| Field | Constraint | Required | Value for the ceremony |
|---|---|---|---|
| `id` | exactly `<lineage_id>-v<version:04d>` | yes | `TLIN-000001-v0001` |
| `lineage_id` | `^TLIN-[0-9]{6}$` | yes | `TLIN-000001` |
| `version` | integer, **exactly `1`** | yes | `1` |
| `lineage_type` | constant | yes | `root-establishment` |
| `authority_id` | `^TAUTH-[0-9]{6}$` | yes | `TAUTH-000001` |
| `subject_type` | **exactly `operator-root`** | yes | `operator-root` |
| `establishment_origin` | one of the named origins | yes | `external-operator-ceremony` |
| `evidence_reference_ids` | **list** of `^TEVID-[0-9]{6}$`, ≥ 1 | yes | `TEVID-000001`…`TEVID-000005` |
| `establishment_audit_id` | `^TAUDIT-[0-9]{6}$` | yes | `TAUDIT-000001` |
| `current_state` | **exactly `trusted`** | yes | `trusted` |
| `established_at` | ISO 8601, timezone-aware | yes | the authority's `created_at` |
| `recorded_at` | ISO 8601, timezone-aware | yes | when the record was written |
| `terminated` | boolean, **exactly `false`** | no, default `false` | `false` |

`version` is exactly 1 and `terminated` exactly false because **advancing or
terminating a root establishment lineage is not defined in this release**. A
version 2, or a terminated root establishment, is a record whose meaning nothing
specifies. `bool` is excluded from `version` explicitly — it is an `int` in
Python, so `version: true` would otherwise pass as 1.

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

The audit identifier is allocated before the lineage is constructed, so the
lineage can name the event recording its establishment. Allocation reserves an
identifier; it writes no record.

**Ordering: evidence, then lineage, then authority, then audit.** Every record
is constructed — and therefore validated — before the first write, so a
declaration that is going to be refused is refused having written nothing. The
lineage is written before the authority that names it, so no partially written
store holds an authority pointing at a lineage record that was never created.

`established_at` and `recorded_at` are both the declaration timestamp on this
path, because declaring is the act of recording. **Nothing in this package reads
a clock**; every timestamp is supplied by the caller, and this path introduces
no exception. The two fields diverge only where establishment and recording are
genuinely separate events — which is why they are separate fields, and what a
later backfill would use them for.

`TrustLineage` construction and `create_decision` are **not touched**.

### Residual risk: the store has no transaction

Multi-record writes are not atomic and nothing here deletes or rewrites, so an
I/O failure or crash between writes leaves a permanent partial state. The
ordering above bounds which one: an orphan lineage with no authority, never an
authority with no lineage.

An orphan root establishment lineage is **not** detected by the validation rule
below, which checks authority → lineage. Detecting it would need the reverse
check, and re-running `init-root` after such a failure would allocate fresh
identifiers and leave the orphan in place permanently. This is inherent to an
append-only store without transactions and is recorded here rather than solved
by ENG-0001.

## The existing production store

`TAUTH-000001` exists and cannot be re-declared — a second active root is
refused, correctly. **Fixing the write path does not retroactively create
`TLIN-000001`.**

Backfill is a **separate, explicitly operator-approved, append-only action**.
ENG-0001 specifies it and does not perform it.

**The backfill creates exactly two new immutable records: `TLIN-000001-v0001`
and a new backfill audit event. It modifies no pre-existing record.
`TAUTH-000001`, `TAUDIT-000001`, and all ceremony evidence records must remain
byte-identical, verified by digest before and after.**

It is refused if a lineage record for `TLIN-000001` already exists, and it
records the operator decision and reason.

Amending the ceremony's audit event is **forbidden**. That event records what
happened at the ceremony. A later repair is a later event, and it gets its own.

### These are constraints, not authorisation

The requirement above is the **mandatory constraint set**. **No backfill is
authorised or executed by this contract, by ENG-0001, or by the pull request
that introduced them.**

Before any execution, a separate operator-approved backfill plan must specify:

| Must specify | Why it cannot be improvised |
|---|---|
| **audit event type** and required fields | the event kind is part of the permanent record |
| **audit identifier allocation** | a wrong identifier cannot be withdrawn |
| **operator identity** and recorded reason | who repaired the root, and why |
| **preconditions and refusal conditions** | when the backfill must decline to run |
| **write ordering and partial-failure handling** | a half-written backfill is permanent |
| **before/after digest verification** | proof that no ceremony record moved |

Write ordering and partial-failure handling deserve the most care. Nothing in
this store deletes or rewrites, so a backfill that writes the lineage and then
fails before its audit event leaves a state no later record can correct.

## Store validation

`validate-store` gains one rule: **every authority's `lineage_id` must resolve
to a `root-establishment` lineage record naming that same authority.**

It reports a problem when the lineage record is absent, when the referenced
lineage is a `subject-decision` lineage rather than a root establishment, when
the stored record carries a forbidden or unrecognised field, and when the
lineage names a different authority than the one referring to it.

### Stored values are validated, not just stored field names

Checking field names alone would let a record whose keys are all correct and
whose values are all nonsense satisfy this rule — malformed data proving a root
was established. So validation **reconstructs `RootAuthorityLineage` from the
stored record** after the field-name checks. Every invariant the model enforces
on construction therefore applies to stored data too, and there is one
definition of a valid root establishment rather than two that can drift apart.

It additionally checks that the stored `id` equals
`<lineage_id>-v<version:04d>`. A file named `v0009` holding version 1 is two
claims about the same record.

`evidence_reference_ids` must be a **list** at this boundary. A stored record
comes from YAML, where a sequence loads as a list; a tuple is a non-list, so
accepting one would mean the boundary was checking an in-memory shape rather
than the stored one. The model keeps a tuple after parsing, which is a separate
question.

**Every failure is a `TrustError`** — including parse, type, and datetime
failures, and a record that is not a mapping at all. `validate-store` reports a
malformed record as a deterministic finding rather than crashing on it.

Findings read *authority, record, reason*, naming each identifier exactly once:

```
TAUTH-000001: TLIN-000001-v0001: established_at is not an ISO 8601 timestamp
TAUTH-000001: TLIN-000001-v0001 names authority 'TAUTH-999999'
TAUTH-000001: lineage 'TLIN-000001' has no lineage record
```

Against the existing production store it reports exactly one finding:

```
TAUTH-000001: lineage 'TLIN-000001' has no lineage record
```

That is accurate — the record is genuinely absent. **Validation reports; it
repairs nothing.** It writes no record, allocates no identifier, and performs no
backfill.

## Related

- [ADR-0014: The Root Establishment Lineage](../decisions/ADR-0014-root-establishment-lineage.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Root authority operations](root-authority-operations.md)
- [Trust states](trust-states.md)
- [Trust Plane runtime overview](runtime-overview.md)
