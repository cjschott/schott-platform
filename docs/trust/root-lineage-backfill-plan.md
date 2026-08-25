# Root Establishment Lineage Backfill Plan

The one-time repair that gives `TAUTH-000001` the root establishment lineage
record its ceremony never wrote.

Required by
[ADR-0014](../decisions/ADR-0014-root-establishment-lineage.md), which
constrains this repair and deliberately does not authorise it, and by the
[contract specification](root-establishment-lineage.md).

> **Status: proposed. Not authorised, and not performed.**
> This document is the plan ADR-0014 requires *before* any execution. Writing
> it authorises nothing. The production store still holds no `TLIN-000001`
> record, and `validate-store` still reports that accurately.

## What is actually wrong

The Operator Root ceremony ran on **2026-08-03T22:00:06+00:00** against commit
`3dd5b84`, whose `declare_root_authority` allocated a lineage identifier for the
authority and wrote no lineage record.

| Evidence | Value |
|---|---|
| `TAUTH-000001.lineage_id` | `TLIN-000001` |
| `TAUDIT-000001.lineage_id` | `TLIN-000001` |
| `lineages/TLIN-000001-v0001.yaml` | absent |
| `sequences/lineage.seq` after the ceremony | `1` |

The allocator returns `current + 1` and stores the result, so `lineage.seq = 1`
means **`TLIN-000001` was allocated and spent**. The identifier exists; the
record does not. That is the whole defect.

Commit `58a56b5` ("persist the root establishment lineage as a dedicated record
type", 2026-08-04T12:59:48+00:00) corrected the write path fifteen hours later.
A corrected write path does not retroactively create a record, and
`declare_root_authority` refuses a second active root — correctly — so the
ceremony cannot be re-run to produce it.

**The validator is not wrong.** It reports a record that is genuinely absent,
in the exact wording this contract predicted.

## The six decisions ADR-0014 requires

### 1. Audit event type and required fields

A new kind, `root-establishment-lineage-backfilled`, on `AuditEventKind`.

It is not `lineage-created`. That event says a lineage began; this one says a
record of one that had already begun was finally written. Reusing it would put
2026-08-25 in the store as the moment the root came into being.

| Field | Value |
|---|---|
| `event_kind` | `root-establishment-lineage-backfilled` |
| `subject_id` | `TAUTH-000001` — the authority whose lineage was recorded |
| `lineage_id` | `TLIN-000001` |
| `actor_authority_id` | `TAUTH-000001` |
| `related_record_ids` | `TLIN-000001-v0001`, `TAUDIT-000001` |
| `occurred_at` | the operator-supplied repair instant |
| `reason` | the operator-supplied written justification |
| `provenance.class` | `repair` |
| `provenance.source` | `operator-approved-backfill` |
| `provenance.performed_by` | the named operator |

### 2. Audit identifier allocation

Allocated by the store's own allocator, `store.allocate_id("audit")` — the next
free `TAUDIT`, expected to be **`TAUDIT-000003`**. `--preflight` predicts it
with `peek_next_id` and spends nothing.

**No lineage identifier is allocated.** `TLIN-000001` was spent in 2026;
writing the record consumes nothing and `lineage.seq` does not move. Any repair
that allocated a fresh `TLIN` would be recording a *different* lineage than the
one the authority names.

**No sequence value is rewritten.** Every sequence already reflects what was
allocated; `lineage.seq = 2` is correct, because `TLIN-000001` and `TLIN-000002`
are both spent.

### 3. Operator identity and recorded reason

Both are mandatory inputs with no default, read from a reviewed file in an
approved directory — never from a command-line argument, an environment
variable, or the invoking user.

`performed_by` must be non-empty. `reason` must be a written justification of at
least five words, the same minimum-substance rule a trust decision reason
carries. A repair to the root of trust that records neither who did it nor why
records nothing.

### 4. Preconditions and refusal conditions

Every one is checked before anything is written. Each refuses; none repairs.

| Condition | Refused because |
|---|---|
| no active operator-root authority | there is no root establishment to record |
| more than one active operator-root | the repair will not choose between them |
| no `root-authority-declared` event naming that authority and lineage | the establishment it would cite has no event to point at |
| more than one such event | which one established it is not something to pick |
| the authority carries no evidence references | the contract requires at least one |
| a cited `TEVID` has no record in the store | it would cite evidence that is not there |
| a cited `TEVID` differs from the stored record | store and authority disagree about what was examined |
| `TLIN-000001` already has more than one stored version | a conflict nothing here resolves |
| `TLIN-000001` holds a record that is not a root establishment | a conflict nothing here resolves |
| `TLIN-000001` holds a root establishment that disagrees with the ceremony | nothing here rewrites it |
| the lineage record **and** a backfill event already exist | already performed; nothing repeats it |
| `recorded_at` has no timezone offset | a time without a zone is not a point in time |
| `reason` under five words, or `performed_by` empty | see §3 |

### 5. Write ordering and partial-failure handling

**Order: lineage, then audit.** The audit event goes last because it records
that the write happened; writing it first would record an event that had not yet
occurred. This matches `declare_root_authority`, where the audit event is also
written last.

The store has no transaction and nothing in it deletes or rewrites, so the
ordering is chosen for which partial state it can leave:

| Interruption point | Resulting state | Recoverable? |
|---|---|---|
| before any write | unchanged | yes — nothing happened |
| between the two writes | lineage present, repair unattributed | **yes — completed, see below** |
| after both writes | complete | n/a |

An interrupted repair is **completed, not repeated**. Re-running finds the
lineage record, verifies it is exactly the record this repair would have written
— every field but `recorded_at` is derived from immutable records, so any
difference is a real disagreement — and then writes only the audit event.
`recorded_at` is read from the stored record rather than compared: the repair is
completed as the repair it already was, not reopened at whatever moment somebody
noticed.

The audit identifier the interrupted attempt allocated stays spent. A gap in the
`TAUDIT` sequence is the honest record of an attempt that did not finish;
reusing the identifier would be the store forgetting it had been handed out.

The reverse ordering has no such recovery: an event describing a record that
does not exist is a claim no later write can make true.

### 6. Before and after digest verification

The operator captures, before and after:

- the whole-store digest of `/var/lib/kyri/trust`;
- the individual digests of `TAUTH-000001`, `TAUDIT-000001`, and
  `TEVID-000001` … `TEVID-000005`;
- every sequence value.

`TAUTH-000001`, `TAUDIT-000001` and all five ceremony evidence records **must be
byte-identical afterwards**. Exactly two paths may appear, and no path may
change:

```
lineages/TLIN-000001-v0001.yaml
audit/TAUDIT-000003.yaml
```

`sequences/audit.seq` advances from `2` to `3`. No other sequence moves.

## What the record will say

Every field is reconstructed from records that already exist and cannot change.
Nothing is invented, and nothing is inferred from a hostname, a clock, or the
invoking user.

| Field | Value | Source |
|---|---|---|
| `id` | `TLIN-000001-v0001` | derived from `lineage_id` and `version` |
| `lineage_id` | `TLIN-000001` | `TAUTH-000001.lineage_id` |
| `version` | `1` | contract: exactly one version exists |
| `lineage_type` | `root-establishment` | constant discriminator |
| `authority_id` | `TAUTH-000001` | the authority record |
| `subject_type` | `operator-root` | `TAUTH-000001.authority_type` |
| `establishment_origin` | `external-operator-ceremony` | the only defined origin |
| `evidence_reference_ids` | `TEVID-000001` … `TEVID-000005` | `TAUTH-000001.evidence_references`, in stored order |
| `establishment_audit_id` | `TAUDIT-000001` | located by kind, subject and lineage |
| `current_state` | `trusted` | `TAUTH-000001.state` |
| `established_at` | `2026-08-03T22:00:06+00:00` | `TAUTH-000001.created_at` |
| `recorded_at` | the repair instant | supplied by the operator |
| `terminated` | `false` | contract |

`established_at` and `recorded_at` differ here, and that is the point. On the
declaration path they are the same instant because declaring is the act of
recording. This is the case the two fields exist for: the establishment happened
in August 2026 and the record of it is being written later.

**Absent, and absent from the model:** `first_decision_id`,
`current_decision_id`, `prior_decision_ids`, `root_authority_id`, `approved_by`,
`approval_source`. No `TDEC` is created, read, or implied. The root was not
decided, and a record claiming otherwise would be a false one.

## What this does not change

`validate-store` keeps every rule it has. A decision or a trust record naming a
lineage that has no record still fails, and a second authority naming a missing
lineage still fails. This repair writes the missing record; it does not teach
the validator to overlook missing records.

`TREC-000001`, `TDEC-000001`, `TLIN-000002-v0001`, `TEVID-000006` and
`TAUDIT-000002` — the first fabric-node trust decision — are untouched. That
chain is internally valid and references `TLIN-000002`; it never referenced
`TLIN-000001`, and the historical defect never affected it.

## Operator procedure

Neither step is authorised by this document.

**1. Rehearse.** Writes nothing, allocates nothing:

```bash
python3 -m tools.trust.cli backfill-root-lineage --preflight \
  --store-root /var/lib/kyri/trust \
  --input-file root-lineage-backfill.yaml \
  --approved-directory /etc/kyri/trust/inputs
```

**2. Apply**, only after the predicted values have been reviewed and the
before-digests captured — the same command without `--preflight`.

The input file holds exactly three fields:

```yaml
recorded_at: "<ISO 8601 instant with a UTC offset>"
performed_by: "<the operator who performed the repair>"
reason: >-
  <why this record is being written, in the operator's own words>
```

## Related

- [ADR-0014: The Root Establishment Lineage](../decisions/ADR-0014-root-establishment-lineage.md)
- [Root establishment lineage contract](root-establishment-lineage.md)
- [Root authority operations](root-authority-operations.md)
- `tools/trust/root_lineage_backfill.py`
- `tests/test-trust-root-lineage-backfill.sh`
