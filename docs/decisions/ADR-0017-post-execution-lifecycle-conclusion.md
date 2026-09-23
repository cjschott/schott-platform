# ADR-0017: Post-Execution Lifecycle Conclusion

- **Status:** Accepted
- **Date:** 2026-09-22
- **Accepted:** 2026-09-23, at G11-BC-AE
- **Decision Makers:** Schott Platform Engineering

> **Scope.** This ADR adds one lifecycle state, one governed operation, one CLI
> verb and one administrative verb to the ENG-0005 first adapter. It changes
> **no existing record schema**, rewrites **no existing record**, and does
> **not** change `MAXIMUM_SLOTS`.

## Context

`CINV-000003` executed successfully on 2026-09-22. The privileged transition
dropped, the governed container ran the payload, disposal was proven, and the
coordinator wrote `CRES-000002`: `outcome_class: completed`, `result_digest`
`sha256:fd2d58e9…cbad7`, `reason: null`.

**And the invocation is still `launch_authorized`.**

That is not a defect in Stage 3. It is the designed behaviour established at
G11-BC-I: the lifecycle journal is written by `authorise_launch` *before* the
privilege boundary is crossed, and the states past `launch_authorized` are
worker-side protocol states that exist on the wire and never in the journal.

The consequence had not been stated until now, and it is the reason for this
ADR:

> **Every successful supervised execution strands.** There is no path in the
> released system by which a supervised invocation reaches `released`, so every
> one of them holds an execution slot for ever.

Measured, not inferred. An AST sweep shows the only lifecycle states any
released code writes are `LAUNCH_AUTHORIZED`, `CLEANED`, `RELEASED` and
`ABANDONED`. The eight intermediate states are never journalled. Reachability
from `launch_authorized` through states that can actually be written yields
exactly one destination: `abandoned`.

Against the released surface, with `CINV-000003` in front of it:

| surface | answer |
| --- | --- |
| a normal transition to a post-result state | none — `launch_authorized` goes only to `abandoned` or `created` |
| `cleanup` | `CINV-000003 is launch_authorized, and cleanup runs only from collected` |
| `capacity.release` | only from `cleaned`; refuses |
| `capability recover` | reports; advances no lifecycle, by design |
| `capability execute` | `TerminalResultExists: … (CRES-000002, outcome completed)` |

`cleanup.cleanup()` and `capacity.release()` have no callers anywhere in the
released package and no CLI verb reaches them.

### The approach that was tried first, and why it failed

The obvious answer is to journal the progression the coordinator actually drove
— `created` through `collected` — and let the existing `cleanup` and
`capacity.release` finish the job. That was implemented and tested at
G11-BC-AD. **It cannot work.**

`cleanup()` records `cleaned` only after the per-`CINV` handoff subtree is gone.
§13's output-leaf ownership transfer gives that leaf to the execution identity:

```
/data/kyri/capability-handoff/CINV-000003        uid=1000 gid=1000 mode=555
/data/kyri/capability-handoff/CINV-000003/out    uid=999  gid=987  mode=700
```

The coordinator is uid 1000. It cannot open `out`, list it, empty it, or
`rmdir` it. Released `cleanup` refuses:

```
CleanupIncomplete: directory 'out' could not be opened as described:
[Errno 13] Permission denied: 'out'
```

and correctly leaves the invocation at `collected`. Nothing in the released
system removes that leaf: the reconcile helper never touches the handoff tree,
no `tmpfiles.d` rule covers it, and the only code that touches `out` is the
transition action that creates and chowns it.

**So `cleaned` is structurally unreachable for every supervised invocation**,
and `released` — which is reachable only from `cleaned` — is unreachable with
it. This is a latent gap between §13 and the cleanup design, not a defect
introduced by Stage 3.

## Decision

Introduce `CONCLUDED` as a **first-class normal closure state** for an
execution that ran.

> `CONCLUDED` means the execution ran, concluded, and its terminal result is
> durable — **and that the cleanup progression did not run.**

It is terminal, it holds no execution slot, and it is neither `released` nor
`abandoned`.

### Why not `RELEASED`

`released` is a specific claim: the work ran, was classified, collected and
cleaned, and the runtime is finished with it. The handoff subtree is still on
disk and cannot be removed. Saying `released` would make the one record that
settles that question untrue — the same objection ADR-0015 raised against
reusing it for work that never ran, applied to work that ran and was never
cleaned.

### Why not `ABANDONED`

ADR-0015 defines `ABANDONED` as closure *"without asserting that the normal
execution and cleanup lifecycle completed"*, and frames it for work that *"never
ran and never will"*. `CINV-000003` ran and succeeded.

The decisive objection is structural, not a matter of taste. Because the
supervised path strands **every** success, abandonment as the standing answer
would record every successful execution as `abandoned` — destroying the property
ADR-0015 exists to create:

> "A stranded invocation is distinguishable from a completed one for ever."

Abandonment remains exactly what it was, for exactly what it was for. The two
closures are different questions and now have different answers.

### Why not repair §13 or add privileged cleanup

Both were considered. Returning the output leaf to the coordinator, or adding a
privileged removal so `cleanup` can complete, would make `released` honestly
reachable — and both change code on or beside the privilege boundary that Stage
3 has just exercised in production. Neither is required to close an invocation
truthfully, and this ADR does not do them. The residue is recorded instead of
hidden, and removing it remains available as a separate, later decision.

## Semantics

### Transition

Added:

```
launch_authorized -> concluded
concluded         -> (nothing)
```

Unchanged: the entire normal progression, `launch_authorized -> created`,
`cleaned -> released`, and every abandonment edge.

`launch_authorized` is the only state that may be concluded, because it is the
only state a supervised invocation is ever left in.

### Capacity

`CONCLUDED` is named explicitly in `NON_SLOT_HOLDING_STATES`, which is the whole
point of stating occupancy as an exclusion: a state added later holds a slot
until somebody decides otherwise, and this is that decision. A concluded
execution has finished and its result is durable, so continuing to hold a slot
for it would be the defect ADR-0015 removed, one invocation further along.

**The slot is released by the transition itself.** Occupancy is counted from
committed lifecycle records, so there is no separate release step to forget, to
repeat, or to race. `MAXIMUM_SLOTS` remains 2.

### Recovery

`CONCLUDED` joins `ABANDONED` in `_ADMINISTRATIVELY_CLOSED`, so recovery may
report it historically and never offers it as something to resume. It is
refused explicitly rather than by falling through the positional lookup — it is
off the linear order, exactly as `ABANDONED` is.

### Two callers, one operation

1. **Inline**, from the supervised coordinator, immediately after a terminal
   result is recorded. This is what makes the change general: every future
   successful execution closes itself.
2. **Administratively**, as `capability conclude`, for an invocation that
   already executed under an earlier generation. `CINV-000003` is the only such
   invocation today.

### Observation versus reconstruction, stated plainly

Inline, the operation closes an execution the same process just supervised.

Administratively, it does not have that trace — the execution happened under a
generation that kept none. The closure rests on the durable terminal result
alone, and the evidence records `derivation: reconstructed` so a reader is never
left to assume which kind of claim it is looking at.

**What licenses the reconstruction.** `supervision.py` states the invariant:

> "A supervised execution that cannot prove its container is gone does not
> return a terminal outcome at all: it raises, so no `CRES` is written and the
> invocation stays unresolved for the readiness gate to find."

A terminal `CRES` from the supervised path is therefore itself proof the
container was created, ran, concluded and was disposed of. The conclusion
asserts nothing the existence of that record does not already establish. It is
**not** a substitute for observation, and the operator ceremony still observes
the container plane before the administrative form is run.

### Evidence

One `CADM` per conclusion, in the existing append-only administrative namespace,
in the shape that namespace already holds every mutating verb to:

```
execution/admin-records/CADM-NNNNNN/intent      verb=conclude, cinv
execution/admin-records/CADM-NNNNNN/conclusion  the detail
execution/admin-records/CADM-NNNNNN/outcome     result=done
```

The `conclusion` member carries `cinv`, `previous_state`, `state` (`concluded`),
`actor`, `request_id`, `recorded_at`, `result_record_id`, `derivation`,
`slot_released`, and **`handoff_retained: true`** — the residue is stated rather
than implied, so a later reader knows the subtree is still there.

**No existing record is rewritten.** The `CINV`, the `CRES`, the launch
authorisation and the published profile are left exactly as they are.

### Idempotency

Repeating the **identical** accepted conclusion reports `resumed: true`,
releases no second slot, and writes nothing. A request differing in actor,
request id, recorded instant, derivation or observed result relationship is
**refused**, naming the field that differs.

An invocation that is `concluded` with no conclusion record, or that carries a
conclusion record while in some other state, is refused as a disagreement
between the lifecycle and the evidence rather than resolved.

### Forbidden

- concluding an invocation with **no** terminal result — that is what recovery
  and the readiness gate are for, and closing it would take it out of the one
  enumeration that could still resolve it;
- concluding from any state but `launch_authorized`;
- concluding an `abandoned` or already-`concluded` invocation, except as the
  idempotent resume above;
- fabricating a result, of any outcome;
- reaching any container. `conclude` is absent from `_DESTROYS_UNDER`, touches
  no container and deletes nothing — the container it concerns was proven gone
  before the result it rests on could be written at all.

### Operator surface

```
capability conclude --expected-uid --expected-gid --cinv --actor
                    --request-id --recorded-at
```

Narrow by construction: one `CINV`, and **no way to name a target state** —
there is no `--to`, no `--force` and no `--state`. It is not a force-transition
command and it is not a repair command.

## Compatibility

- No record schema changes and no migration.
- `released` still means what it meant, and is untouched. This change does not
  widen it.
- `abandoned` still means what it meant, and its two reason categories are
  unchanged.
- A reader older than this ADR refuses a `concluded` record as an unknown state
  rather than misinterpreting it, which is the correct direction.
- Invocations with no terminal result are untouched: `CINV-000001` remains
  `launch_authorized` and remains in the recovery enumeration.

## Consequences

**Good.** A successful supervised execution can be closed truthfully and return
its slot, which the lifecycle had no path to. The distinction abandonment
protects is preserved, because abandonment is no longer the only exit. Future
successes close themselves.

**Accepted cost.** The lifecycle vocabulary grows by one state and the
administrative verb set by one verb — both closed sets whose value is that
additions are reviewed, and this addition is that review. The administrative
form writes a closure derived from the result rather than observed, which is why
the derivation is recorded and why the ceremony observes the container plane
first.

**Residual risk, stated rather than hidden.** The per-`CINV` handoff subtree is
left on disk for every concluded invocation and accumulates. `handoff_retained`
records it on each conclusion. Removing it requires either returning the output
leaf at §13 or a privileged removal, and that decision is deliberately not taken
here.
