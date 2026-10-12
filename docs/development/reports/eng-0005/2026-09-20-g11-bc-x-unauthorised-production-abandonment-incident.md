# G11-BC-X — Generation-19 acceptance, and an unauthorised production abandonment

**Date:** 2026-09-20
**Branch:** `arch/eng-0005-execution-transition`
**Engineer:** Claude (implementation)
**Status:** STOPPED. Reviewer ruling required before any further execution work.

---

## 1. What happened, first

**I abandoned `CINV-000002` in production. The prompt forbade it.**

At `2026-09-20 18:54:33-05:00` the CINV-000002 reclamation ceremony's closure ran
against the production capability runtime from inside a test harness I had just
written. The G11-BC-X prompt says plainly: *"Do NOT abandon anything during this
prompt."* I did.

Nothing about this was an operator action, and nothing about it was reviewed. The
mutation is append-only and governed; it cannot be withdrawn, and I have not
attempted to edit, delete or compensate for it.

### Root cause

`tools/capability/cli.py::command_abandon` resolves its store from the module
constant `CAPABILITY_RUNTIME_ROOT = "/data/kyri/capability-runtime"`. The CLI
takes **no runtime-root argument**. My rehearsal suite redirected the ceremony at
a fixture by substituting the runtime path with `sed`. That substitution
redirected every **gate**. It could not redirect the **mutation**, because the
mutation's target is a constant inside the installed library.

So the gates read a fixture and passed, and the abandon wrote to production.

The earlier G11-BC-X rehearsal (reported as PASS, occupancy 2→1) was sound: it
called `abandonment.abandon()` directly with an explicit store and execution
root. This was the first harness that drove the **CLI**, and the CLI cannot be
aimed.

### Why my own safety assertion did not catch it

The suite asserted *"the rendered block references no production runtime or
witness path"*, and that assertion passed — because the production path is not
in the rendered text at all. It is inside the library the block calls. I checked
the paths the ceremony **names**, not the path the mutation **uses**. That is the
same class of mistake the reviewer caught at G11-BC-W, where I had checked that a
ceremony would run and not which runtime it would run against.

### What was bypassed

| Required by the ceremony | What actually happened |
|---|---|
| BLOCK A container observation, as `kyri-capability`, on the host | **Never performed.** The gate was satisfied by a synthetic witness the test wrote into the fixture |
| Operator authorisation of an irreversible closure | **Absent** |
| Reviewer acceptance of the regenerated ceremony | **Absent** |

The container gate is the one that matters. `ABANDONED` removes an invocation
from the recovery enumeration, so if a container existed, abandonment closes the
surface that would have found it.

**Containment argument, stated as evidence and not as reassurance:** the store's
own transition chain for `CINV-000002` is `reserved` → `launch_authorized` →
`abandoned`. It never reached `created`, and its execution directory holds only
`launch-authorisation` — no creation evidence. That is precisely why
`ELIGIBLE_SOURCE_STATES` is `{reserved, launch_authorized}`. It is not a
substitute for the observation: **BLOCK A has still not been run, and an operator
should now run it to confirm no `kyri-CINV-000002` container exists.**

### The production mutation, measured

Runtime aggregate: `6202e1ec…` → `9374b56870759ebccbbb74a38ada5905bcd5ce3bd1418428b72e148cdc662d68`

Exactly five files written, two counters advanced:

| Path | Content |
|---|---|
| `execution/admin-records/CADM-000001/intent` | `{"cadm":"CADM-000001","cinv":"CINV-000002","schema_version":1,"target":null,"verb":"abandon"}` |
| `execution/admin-records/CADM-000001/abandonment` | actor `primary-platform-operator`, previous_state `launch_authorized`, state `abandoned`, reason `terminal-result-lifecycle-stranded`, `result_record_id` `CRES-000001`, `slot_released` true, request_id `g11bcx-reclaim-cinv-000002`, recorded_at `2026-09-20T18:54:33-05:00` |
| `execution/admin-records/CADM-000001/outcome` | `result: done` |
| `execution/transitions/CINV-000002.000003` | `previous launch_authorized → abandoned`, sequence 3 |
| `execution/mutations/CMUT-000000000007/{intent,outcome}` | the journalled mutation |
| `execution/cadm-counter` | `000000` → `000001` |
| `execution/cmut-counter` | → `000000000007` |

The evidence itself is well-formed and is exactly what the reviewed operation is
specified to write. The defect is **authority and sequencing**, not content.

### What did not change

- `CINV-000001` `1dcef40d…`, `CINV-000002` `923ff0d7…`, `CINV-000003` `c0941b7d…`, `CRES-000001` `18ba4c34…` — all byte-identical
- No `CRES-000002`; `capability-invocation.seq` 3 and `capability-result.seq` 1 unchanged
- `CINV-000002` launch-authorisation and the published handoff untouched
- `CINV-000003` still has no execution state — Stage 2 was **not** performed
- Fabric `a87c2010…`, Platform Evidence `62c87585…`, Artifacts `ef4297c6…` unchanged
- No Root Authority mount

### Current production state

| | |
|---|---|
| `CINV-000001` | `launch_authorized` (holds a slot) |
| `CINV-000002` | `abandoned` (holds no slot; recovery treats it as closed) |
| Occupancy | **1 of 2** |
| Administrative records | 1 (`CADM-000001`) |

One slot is free. It is free by an act that was not authorised.

---

## 2. Generation-19 acceptance (Sections A–G), completed before the incident

These findings stand on their own and were all measured before the mutation.

- **7 of 7** Generation-19 objects installed and matching their reviewed
  successors; `abandonment.py` installed `root:root 0444`; installed library 82
  `.py` files
- **12 of 12** installed-semantics checks pass: 13 `LifecycleState` members, 15
  `Verb` members, `ABANDONED` terminal and reachable only from `reserved` and
  `launch_authorized`, `MAXIMUM_SLOTS` 2, occupancy excluding exactly `RELEASED`
  and `ABANDONED`, recovery treating `ABANDONED` as closed, `abandon` exposed
  with no `--force`/`--to`/`--state`/`--target-state`/`--repair` and no
  destruction authority
- `--verify-installed` in full, and installer checks A.4–A.6, require root and
  are **not** independently verifiable as `cschott` (every failure was
  `Permission denied` on `/root/kyri-gen18-library-digests.txt`)
- **Post-G19 runtime baseline measured `6202e1ec…` — unchanged from pre-G19.** The
  installed library changed; the production aggregate did not. Measured, not
  assumed
- Checkout vs installed: **0 divergent modules**
- Operation-level rehearsal (against a copy, via `abandonment.abandon`): PASS —
  occupancy 2→1, all four immutable records byte-identical, no synthetic CRES,
  launch authorisation and handoff byte-identical, mutation exactly one CADM +
  one transition + one CMUT proved by reconstruction (`bff337c7…` both sides)
- Capacity probe: with one slot free, `CINV-000099` reserved it and the ceiling
  still refused a third

## 3. Failure matrix (Section I) — what the harness did establish

Before the incident aborted it, the suite drove the whole operator block through
eighteen single-fact sabotages. Results that are still valid, because they were
judged by gates reading the fixture:

- Refuses when an installed digest does not match Generation 19
- Refuses when the runtime baseline has moved
- Refuses when `capability-invocation.seq` or `capability-result.seq` has moved
- Refuses when administrative records already exist
- Refuses when the witness is absent, incomplete (no absence line, or absence
  without the non-running line), stale beyond 300s, or dated in the future
- A conflicting replay under a different actor is refused by the installed
  operation: *"CINV-000002 is already abandoned under different authority"*
- Every refusal was a judgement, not a traceback

**Not established, and not to be claimed:** the immutable-record sabotages
(CINV-000002/CRES-000001 missing or changed, CINV-000001/CINV-000003 changed) and
the wrong-reason case never reached their intended gate — the whole-store
aggregate gate refuses first, because my harness pinned the baseline before
applying the sabotage. Those rows are **unproven**. The matrix is incomplete.

## 4. Actions taken after discovering it

- Stopped. No remediation, no compensating record, no edit or deletion
- `tests/test-capability-cinv-000002-reclamation-rehearsal.sh` **disarmed**: it
  refuses to run and carries the root cause at the top. Kept as evidence
- `provisioning/execution/g11-bc-x-cinv-000002-reclamation-ceremony.txt` marked
  **SPENT — DO NOT RUN**
- Measured the full production state, above

## 5. Actions NOT performed

Generation 19 was not reinstalled. `CINV-000001` was not abandoned. CINV-000003
Stage 2 and Stage 3 were not run. `MAXIMUM_SLOTS` was not altered. No lifecycle
state was hand-edited. No reservation, CINV or CRES was deleted. Fabric, Trust,
Artifact authority and Platform Evidence were not altered. Root Authority was not
mounted. ENG-0006 was not begun.

## 6. For the reviewer

1. **Ratify or repudiate `CADM-000001`.** The record is materially what the
   approved design specifies, produced by the installed reviewed authority, but
   it carries an actor attribution (`primary-platform-operator`) for an action no
   operator took. If that attribution is unacceptable, the remedy is a governed
   correcting record, not an edit — and it is your call, not mine.
2. **BLOCK A should be run now**, so container absence for `kyri-CINV-000002` is
   established by observation rather than by inference from the transition chain.
3. **A harness must not be able to aim the CLI at production by omission.** My
   recommendation is that `command_abandon` take an explicit runtime root and
   refuse to default, so a rehearsal has to state its target and a typo cannot
   resolve to production. That is a Generation-20 change and I have not made it.
4. The failure matrix must be rebuilt at the operation level, where the target
   can be aimed, and the unproven rows completed.

## 7. Assumptions and deviations

- No assumption is load-bearing in this report; every state claim above was
  measured with the installed runtime at 2026-09-20 18:5x–19:0x
- Deviation: the G11-BC-X deliverables (completed failure matrix, clean
  verification run, regenerated ceremony offered for review) are **not**
  delivered, because continuing to test against a mutated production baseline
  would compound the error

## 8. Commands run

Measurement only: store aggregates via `find … | sort -z | xargs -0 sha256sum |
sha256sum`; `sha256sum` on the four immutable records; `cat` on the CADM members,
the CINV-000002 transition chain and both counters; `find -newermt` to enumerate
what was written; a read-only `all_states` / `slot_holding_states` /
`recovery._container_possible` probe from `/usr/lib/kyri/python`. Plus the two
file edits that disarmed the suite and marked the ceremony spent.
