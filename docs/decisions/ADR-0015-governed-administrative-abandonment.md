# ADR-0015: Governed Administrative Abandonment

- **Status:** Accepted
- **Date:** 2026-09-20
- **Decision Makers:** Schott Platform Engineering

> **Scope.** This ADR adds one lifecycle state, one administrative verb, one
> CLI operation and one evidence member to the ENG-0005 first adapter. It
> changes no other behaviour, changes no existing record, and does **not**
> change `MAXIMUM_SLOTS`.

## Context

The execution plane admits two concurrent invocations. The ceiling is counted
from committed lifecycle records, and every state except `released` holds a
slot — deliberately, so that stuck work halts new execution rather than
silently oversubscribing the host.

`released` is reachable only from `cleaned`, at the end of the full execution
lifecycle. That is correct for work that ran. It has no answer for work that
**never ran and never will**.

G11-BC-U found the consequence in production. Two invocations were stuck at
`launch_authorized` and between them held both slots:

| invocation | state | terminal result | why it is stuck |
| --- | --- | --- | --- |
| CINV-000001 | `launch_authorized` | none | its Stage 3 never completed |
| CINV-000002 | `launch_authorized` | CRES-000001, `provider-error` | answered, but the lifecycle never advanced |

CINV-000003 was prepared and accepted, and its `authorise-launch` refused with
`CapacityExhausted` before mutating anything. Nothing in the released surface
could free either slot:

- `launch_authorized -> released` is not a permitted transition, and
  `capacity.release` therefore refuses;
- `capability recover` writes nothing by design — it resolves containers, not
  lifecycle state;
- the administrative verb set is closed and contains no repair, force, delete
  or generic cleanup;
- `execute` refuses an invocation that already has a terminal result, so
  CINV-000002 cannot be driven forward even in principle.

The platform could reach a state it had no governed way to leave.

## Decision

Introduce `ABANDONED` as a **first-class exceptional closure state**.

> `ABANDONED` means the invocation was permanently administratively closed
> **without asserting that the normal execution and cleanup lifecycle
> completed.**

It is terminal, it holds no execution slot, and it is **not** `released`.

### Why `RELEASED` is insufficient

`released` is a claim: the work ran, was classified, collected and cleaned, and
the runtime is finished with it. Reusing it for an invocation that never ran
would make an unfinished execution indistinguishable from a finished one in the
one record that is supposed to settle the question. Every later reader —
recovery, audit, a human — would be told something untrue.

The two states exist precisely so the difference survives. Nothing in this
design ever reports one as the other.

### Why raising `MAXIMUM_SLOTS` was rejected

The ceiling was not the defect. It did exactly what it is for: it refused to
oversubscribe a host that already had two unfinished executions. Raising it
would have removed the control and left the real problem — that a slot could
never be given back — in place, one invocation further along.

### Why manual state repair was rejected

The lifecycle journal is append-only, create-once, and validated as a
contiguous chain on every read. It is the authority that survives a crash.
Editing it by hand, deleting a reservation, or synthesising a `cleaned` record
would forge the one history the runtime trusts, and would do so in a way no
later reader could detect. A governed operation that says what it did is
strictly better evidence than a quiet edit that does not.

### Why no result is fabricated

Abandonment writes no `CRES`. An invocation that never produced a result still
has none afterwards. A synthesised success would be a lie; a synthesised
failure would close a question against the recovery enumeration that could
still have answered it. Where a terminal result already exists it is preserved
untouched and referenced by identity.

## Semantics

### Transitions

Added:

```
reserved          -> abandoned
launch_authorized -> abandoned
abandoned         -> (nothing)
```

Unchanged: the entire normal progression, `cleaned -> released`, and
`released -> (nothing)`.

**Only the two states the coordinator wrote before handing anything over may be
abandoned.** From `created` onwards a container provably exists on the far side
of the privilege drop. Closing those administratively would strand it, and
container reconciliation is what the §20 administrative verbs already have
authority for — abandonment must not become a way around them.

### Forbidden

- `authorise-launch` on an abandoned invocation — it falls to the bridge's
  existing refusal branch for a state no longer awaiting authorisation;
- `execute` on an abandoned invocation — no transition out of `abandoned`
  exists, so the launch transition refuses;
- any normal cleanup progression out of `abandoned`;
- re-reserving a slot for an abandoned invocation — `reserve` already refuses a
  `CINV` that has durable execution state;
- recovery proposing an abandoned invocation as resumable.

### Capacity

The occupancy model is stated as an **exclusion**:

```python
NON_SLOT_HOLDING_STATES = frozenset({RELEASED, ABANDONED})
SLOT_HOLDING_STATES = tuple(s for s in LifecycleState
                            if s not in NON_SLOT_HOLDING_STATES)
```

Exclusion rather than inclusion on purpose: a lifecycle state added later then
holds a slot until somebody decides otherwise, which is the safe direction. An
inclusive list would let a new state silently consume nothing.

**The slot is released by the transition itself.** Occupancy is counted from
committed lifecycle records, so an invocation stops holding a slot the moment
its `abandoned` record is durable. There is no separate release step to forget,
to repeat, or to race — which is also why double-release is not representable.

`MAXIMUM_SLOTS` remains 2.

### Concurrency

Abandonment takes the capacity lock and then the `CINV` lock, in that order —
the same order `reserve` takes. The whole decision (read state, read evidence,
decide, write evidence, commit the transition) happens under both, so two
actors cannot read the same occupancy and both act on it. Lock inversion
raises, as it already did.

## Evidence

Abandonment reuses the existing append-only administrative namespace rather
than inventing a second one. One `CADM` per accepted abandonment, with the
convention that namespace already holds every mutating verb to — **intent, one
attempt, outcome, in that order, each durable and create-once**:

```
execution/admin-records/CADM-NNNNNN/intent        verb=abandon, cinv
execution/admin-records/CADM-NNNNNN/abandonment   the administrative detail
execution/admin-records/CADM-NNNNNN/outcome       result=done
```

The `abandonment` member is a new create-once member alongside `intent` and
`outcome` — the same shape `record_reconciliation` already uses. **No existing
record schema changes.** It carries:

| field | |
| --- | --- |
| `cinv` | the invocation closed |
| `previous_state` | the state it was closed from |
| `state` | `abandoned` |
| `actor` | who closed it |
| `request_id` | the authorising request |
| `recorded_at` | ISO-8601 with a timezone offset, refused without one |
| `reason` | a controlled category (below) |
| `result_record_id` | the existing `CRES`, or `null` |
| `causal_references` | the invocation and any result |
| `slot_released` | whether this act released a slot |
| `cadm` | its own identity |

Historical evidence is never rewritten. The `CINV`, any `CRES`, the launch
authorisation and the published handoff are all left exactly as they are.

### Reason categories

Closed, because a free-form reason makes an audit answerable only by reading
prose, and the two production cases are genuinely different questions:

| category | meaning |
| --- | --- |
| `terminal-result-lifecycle-stranded` | a terminal result exists and the lifecycle never advanced, so capacity stayed held for an invocation that was already answered |
| `historical-incomplete-execution` | no terminal result exists and the historical invocation cannot safely resume |

**The category is checked against what the store holds.** Claiming a stranded
terminal result for an invocation that has none is refused, and so is the
reverse. A category cannot be used to describe a situation that is not the one
in front of the operator.

## Idempotency

Repeating the **identical** accepted abandonment reports `resumed: true`,
releases no second slot, and writes nothing. A request that differs in actor,
request id, recorded instant, reason or observed result relationship is
**refused**: a second authority for the same closure is a decision nobody made.

An invocation that is `abandoned` with no administrative record, or that
carries an abandonment record while in some other state, is refused as a
disagreement between the lifecycle and the evidence rather than resolved.

## Operator surface

```
capability abandon --expected-uid --expected-gid --cinv --actor
                   --request-id --recorded-at --reason {…}
```

Narrow by construction. One `CINV`, one controlled reason chosen from a closed
set the parser enforces, and **no way to name a target state** — there is no
`--to`, no `--force` and no `--state`. It is not a force-transition command and
it is not a repair command.

`abandon` is added to the closed administrative verb set and is absent from the
destruction-authority mapping: it touches no container and deletes nothing.

## Compatibility

- No existing record is rewritten and no bulk migration is performed.
- Existing lifecycle state files remain readable and their meaning is
  unchanged. `released` still means what it meant.
- Every currently active state remains active and still holds its slot.
- Only invocations explicitly reviewed and named in an operator ceremony are
  ever abandoned.
- A reader older than this ADR would refuse an `abandoned` record as an unknown
  state rather than misinterpret it, which is the correct direction.

## Consequences

**Good.** The platform can now leave a state it previously could not, and it
does so through a governed operation that records what it did and why. The
capacity ceiling keeps its meaning. A stranded invocation is distinguishable
from a completed one for ever.

**Accepted cost.** The lifecycle vocabulary grows by one state and the
administrative verb set by one verb. Both are closed sets whose whole value is
that additions are reviewed, and this addition is that review.

**Residual risk.** Abandoning an invocation removes it from the recovery
enumeration. If a container could still exist for it, abandonment closes the
one surface that would have found it. The engine does not attempt to prove
container absence — that is what `recover` and the reconciliation verbs are
for. **The operator ceremony is therefore required to observe the container
state first**, and the ceremonies for CINV-000001 and CINV-000002 do.
