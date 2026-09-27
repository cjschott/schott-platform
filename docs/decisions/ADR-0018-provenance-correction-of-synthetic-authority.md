# ADR-0018: Provenance Correction of Synthetic Authority

- **Status:** Accepted
- **Date:** 2026-09-24
- **Accepted:** 2026-09-27, at G11-BC-AI
- **Decision Makers:** Schott Platform Engineering

> **Scope.** This ADR widens one closed set and adds one finding category to the
> ADR-0016 correction. It adds **no lifecycle state**, **no verb**, changes **no
> record schema**, reverses **nothing**, and does **not** change
> `MAXIMUM_SLOTS`.

## The four things this ADR keeps apart

Every difficulty in this record comes from conflating them, so they are named
first and never merged afterwards.

| | what it is | for `CADM-000004` |
|---|---|---|
| **1. lifecycle truth / effect** | what actually happened to the invocation | `CINV-000001` is `abandoned`, it had no terminal result, and `historical-incomplete-execution` is the category the store admits. **True, and retained.** |
| **2. asserted administrative authority** | who the record claims decided it, under what request, and when | `actor x`, `request_id y`, `recorded_at 2026-09-20T20:00:00-05:00`. **Rejected.** |
| **3. disputed synthetic provenance** | the recorded values themselves, preserved as evidence | the three literals above, kept byte-for-byte in a record nothing rewrites. |
| **4. actual occurrence evidence** | what is observably true about when and by what the action happened | `2026-09-24T06:40:43-05:00`, by an unauthorised test harness. |

A correction under this ADR touches **2, 3 and 4 only**. It cannot reach 1. That
is the whole boundary, and every refusal below exists to hold it.

**This is not generic record rewriting.** There is no path here to editing a
subject, no path to a lifecycle claim, and no path to a field outside a closed
set of three. A correction adds evidence beside a record; it never replaces one.

## Context

On 2026-09-24 at 06:40:43-05:00, `test-capability-execution-generation20-installer.sh`
abandoned `CINV-000001` in production. The full escape path is recorded at
G11-BC-AH. The reviewer has ruled:

- **the lifecycle effect is RETAINED** — `CINV-000001` had no terminal result
  and was stuck at `launch_authorized`, so `historical-incomplete-execution`
  describes its actual condition and `ABANDONED` is semantically right;
- **the asserted authority is REJECTED** — no operator performed it.

`CADM-000004` therefore carries a truthful *effect* under three false
*assertions*:

| field | recorded | actual |
|---|---|---|
| `actor` | `x` | an unauthorised test harness |
| `request_id` | `y` | no request was made |
| `recorded_at` | `2026-09-20T20:00:00-05:00` | `2026-09-24T06:40:43-05:00` |

The `recorded_at` is not merely wrong, it is **backdated by four days** — to a
literal that lived in the test. A reader taking it at face value places the
action before the Generation-20 publication that was supposed to make it
impossible.

### Why ADR-0016 as it stands cannot record this

Measured against the released module, not assumed:

```
CORRECTABLE_FIELDS : ['actor']
FINDINGS           : ['attribution-not-authorised']

actor        = 'x'                          correctable: True
request_id   = 'y'                          correctable: False
recorded_at  = '2026-09-20T20:00:00-05:00'  correctable: False
```

`correct_provenance` refuses any field outside the closed set. So two of the
three false assertions **cannot be recorded at all**.

The structure is otherwise right. Corrections are deduplicated on
`(subject_cadm, disputed_field)`, so one record per disputed field is already
the model's own shape — three corrections would be three distinct records with
no schema change. What is missing is only the permission to name the other two
fields.

**The alternative was considered and rejected.** A single `actor` correction
whose `actual_initiator` names the harness would record *who*, and would leave
the backdating and the synthetic request id unrecorded — or force them into
free text, which is schema abuse: a field that means one thing being used to
carry another because the right field was unavailable.

## Decision

Widen `CORRECTABLE_FIELDS` from `{actor}` to `{actor, request_id, recorded_at}`,
and add one finding category for an assertion that is not merely unauthorised
but **fabricated**.

```python
CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT})

FINDING_NOT_AUTHORISED = "attribution-not-authorised"   # ADR-0016, unchanged
FINDING_SYNTHETIC      = "assertion-synthetic"          # ADR-0018
FINDINGS = frozenset({FINDING_NOT_AUTHORISED, FINDING_SYNTHETIC})
```

`assertion-synthetic` means: **the recorded value was never asserted by any
authority — it is a literal that reached the record through a mechanism that had
no standing to assert anything.** That is precisely true of `x`, `y`, and a
timestamp copied out of a test.

### What a correction still cannot do, unchanged from ADR-0016

- it reaches **no lifecycle claim** — `CORRECTABLE_FIELDS` names only assertions
  about *who, under what request, and when*, never about *what happened*;
- it writes **no transition** and takes **no capacity lock**, so it can move no
  slot;
- it **opens nothing for writing** — `CADM-000004` stays exactly as it is;
- it **reverses nothing**. The abandonment stands, and the correction says so
  explicitly.

The three fields added are all assertions about the *authority* of a record.
None of them is an assertion about the *effect*. That boundary is what keeps a
correction from becoming a reversal, and this ADR does not move it.

### Why `reason` is NOT added to the correctable set

`reason` is a claim about what happened, not about who claimed it — and here it
is **true**. The released rule is explicit:

```python
_REASON_REQUIRES_RESULT = {
    REASON_TERMINAL_RESULT_STRANDED: True,
    REASON_HISTORICAL_INCOMPLETE_EXECUTION: False,
}
```

`CINV-000001` has no terminal result, so `historical-incomplete-execution` is
the category the store itself admits — and the released code validated that
before writing. Adding `reason` to the correctable set would open the door to
disputing an effect through a mechanism built to dispute an attribution.

## Semantics

### Three corrections, not one

One `CADM` per disputed field, each carrying its own `disputed_value` and
`finding`. `actual_initiator` names the same subject in all three, because it is
the same subject.

| disputed_field | disputed_value | finding |
|---|---|---|
| `actor` | `x` | `attribution-not-authorised` |
| `request_id` | `y` | `assertion-synthetic` |
| `recorded_at` | `2026-09-20T20:00:00-05:00` | `assertion-synthetic` |

### Three timestamps, three names, no overloading

A `recorded_at` correction involves three distinct instants, and a single field
carrying two of them would be the same class of defect as the one being
corrected. Each has its own name:

| field | what it means |
|---|---|
| `disputed_value` | the subject's own `recorded_at` — the **false** literal, preserved |
| `actual_occurrence_at` | when the action **observably** happened |
| `recorded_at` | when **this correction** was written |

`actual_occurrence_at` is new in this ADR and carries no authority claim: it is
an observation, not a decision. It is recorded on **every** correction under this
ADR, not only the `recorded_at` one, because *when the disputed action actually
happened* is a fact about the subject rather than about which field is being
disputed.

It does **not** substitute a corrected timestamp into `CADM-000004`, and it does
**not** claim anyone was authorised at either instant. The false value is
preserved as disputed evidence and the observed occurrence is recorded beside
it.

### Bound to the member, not just the record

The released mechanism already resolves the **one** member of the subject that
carries the disputed field and records `subject_member` with the SHA-256 of that
member's bytes. A field appearing in two members is refused as ambiguous rather
than guessed at. For `CADM-000004` all three disputed fields are carried by
`abandonment` and by nothing else, verified against the record.

That binding is what makes a correction falsifiable: if the subject member ever
differed from the bytes a correction was written against, the mismatch is
visible.

### What is never claimed

- that an operator performed the abandonment;
- that the abandonment was authorised;
- that the effect is reversed, pending, or conditional;
- any substitute `actor`, `request_id` or `recorded_at` presented as the real
  authority. There was none, and inventing one would repeat the original fault
  in the opposite direction.

## Compatibility

- No record schema changes. `provenance.py`'s detail members are unchanged; only
  which `disputed_field` values are admissible moves.
- Existing `CADM-000002` (the ADR-0016 correction of `CADM-000001`) is untouched
  and still valid: `actor` remains correctable and
  `attribution-not-authorised` remains a finding.
- A reader older than this ADR refuses an unknown `disputed_field` or `finding`
  rather than misreading it, which is the correct direction.
- `MAXIMUM_SLOTS` unchanged at 2; occupancy unchanged at 0 of 2.

## Consequences

**Good.** All three false assertions in `CADM-000004` become recordable, as
three narrow append-only findings, without touching the record they dispute and
without reversing an effect the reviewer has accepted as truthful.

**Accepted cost.** A closed set grows by two members and a finding vocabulary by
one. Both are closed sets whose value is that additions are reviewed, and this
ADR is that review.

**Residual risk.** A correction can now dispute *when* a record says it was
written. That is a stronger claim than disputing *who*, because a timestamp is
load-bearing for ordering. It is deliberately confined to disputing the value
and recording an observed occurrence beside it — never to rewriting the subject,
and never to reordering anything.

## Implementation

Ratified at G11-BC-AI with exactly this scope: three correctable fields, two
findings, `reason` excluded. Published by **Generation 22**, prepared at
G11-BC-AI and not installed.
