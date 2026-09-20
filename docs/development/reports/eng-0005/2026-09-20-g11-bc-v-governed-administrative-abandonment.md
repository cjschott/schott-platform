# G11-BC-V — governed administrative abandonment

ENG-0005. 2026-09-20. Branch `arch/eng-0005-execution-transition`.

An architecture correction, prompted by the production capacity blocker
G11-BC-U found. `ABANDONED` is added as a first-class exceptional closure
state, with one narrow governed operation to reach it.

`MAXIMUM_SLOTS` is unchanged. No production state was mutated. CINV-000003
Stage 2 was not prepared and not run.

---

## 1. Source authority

| | |
| --- | --- |
| HEAD at start | `0722c3a5a7a8d5f216ef57227bfa3cb04be65402` ✔ |
| branch | `arch/eng-0005-execution-transition` ✔ |
| origin | contains HEAD; tree clean ✔ |

---

## 2. The released model, reconstructed

Read from `types.py`, `state.py`, `capacity.py`, `recovery.py`, `admin.py`,
`launch.py`, `cleanup.py`, `mutation.py` and `identifiers.py` before anything
was changed.

**Lifecycle.** Twelve states, strictly linear, enumerated from §16 rather than
inferred from enum order. `_ALLOWED` is written out explicitly *"so that adding
a state to the vocabulary does not silently create new legal transitions"*.

**State storage.** Append-only. `Mutation.install` is create-once by design, so
one mutable file per `CINV` is impossible; each transition is its own immutable
record and the current state is the last record of a **validated contiguous
chain**. A gap, a contradiction or an illegal transition is refused on read.

**Capacity.** Counted from committed lifecycle records and nothing else — not
process counts, not container counts, not lock files. Two slots, no queue. Every
state except `released` held one. `release()` requires a transition to
`RELEASED`, reachable only from `CLEANED`.

**Locking.** Global capacity lock, then per-`CINV` lock; inversion raises. The
`CINV` lock spans read, validate, decide and commit.

**Administrative authority.** A closed verb set, a `CADM` counter, and
create-once `intent` → `outcome` records under `execution/admin-records/`.
`record_reconciliation` already adds a third create-once member per `CADM`, so
a per-record member is an established shape. The module states its own limit:
*"There is no shell, no Podman argv, no caller path, no caller-supplied
identity, no repair, and no force."*

**Recovery.** Read-only. Finds invocations with no terminal result that either
carry an adapter identity or have reached a state where a container could
exist, the latter by positional comparison against `_LIFECYCLE_ORDER`.

### Surfaces affected by adding a state

| surface | effect |
| --- | --- |
| `types.LifecycleState` | one member added |
| `state._ALLOWED` | two new edges in, none out |
| `capacity` occupancy set | must exclude the new state |
| `recovery._container_possible` | **positional** — needed explicit handling |
| `admin.Verb` | closed set, one member added |
| `cli` verb set | closed set, one subcommand added |
| four closed-set test guards | must be updated to the new vocabulary |

**The positional read was the trap.** `recovery._LIFECYCLE_ORDER` is an explicit
tuple and `_container_possible` compares indices. Appending `ABANDONED` to the
enum and leaving it out of that tuple would make `.index()` raise, the existing
`except ValueError` return `False`, and the right answer arrive **by accident**.
An accident is not a safety property, so the module now refuses administratively
closed states explicitly and says why.

Nothing in the released model contradicted the ruling.

---

## 3. RED evidence

`tests/test-capability-execution-abandonment.sh`, run before any implementation:

```
2 PASS, 21 FAIL
```

The two passes are the blocker itself, reproduced against fixtures:

```
PASS: two launch_authorized invocations hold both slots and a third is refused
      reproduced: all 2 execution slots are held
PASS: launch_authorized cannot reach released, so no slot can be given back
      confirmed: launch_authorized -> released is not a permitted transition
```

---

## 4. The design

### `ABANDONED`

> The invocation was permanently administratively closed **without asserting
> that the normal execution and cleanup lifecycle completed.**

Terminal. Holds no execution slot. **Not** `released` — `released` is a claim
that the work ran and was classified, collected and cleaned. Reusing it would
make an unfinished execution indistinguishable from a finished one in the
record that is supposed to settle the question.

### Transitions

```
reserved          -> abandoned
launch_authorized -> abandoned
abandoned         -> (nothing)
```

**Only the two states the coordinator wrote before handing anything over.** From
`created` onwards a container provably exists on the far side of the privilege
drop; closing those administratively would strand it, and container
reconciliation is what the §20 verbs already have authority for. Abandonment
must not become a way around them.

### Capacity

```python
NON_SLOT_HOLDING_STATES = frozenset({RELEASED, ABANDONED})
SLOT_HOLDING_STATES = tuple(s for s in LifecycleState
                            if s not in NON_SLOT_HOLDING_STATES)
```

Stated as an **exclusion**, not an inclusion. A lifecycle state added later then
holds a slot until somebody decides otherwise, which is the safe direction; an
inclusive list would let a new state silently consume nothing and oversubscribe
the host. `CAPACITY_CONSUMING_STATES` is retained as the same tuple so existing
importers keep working.

**The slot is released by the transition itself.** Occupancy is counted from
committed lifecycle records, so an invocation stops holding a slot the moment
its `abandoned` record is durable. There is no separate release step — which is
why double-release is not representable rather than merely prevented.

### The operation

```
capability abandon --expected-uid --expected-gid --cinv --actor
                   --request-id --recorded-at --reason {…}
```

One `CINV`, one controlled reason the parser enforces from a closed set, and
**no way to name a target state** — no `--to`, no `--force`, no `--state`.

It validates the invocation record, reads any terminal result, takes the
capacity lock then the `CINV` lock (the same order `reserve` takes), checks
eligibility, writes evidence, commits the transition, and returns. `rc=0`.

### Reason categories

| category | meaning | production case |
| --- | --- | --- |
| `terminal-result-lifecycle-stranded` | a terminal result exists and the lifecycle never advanced | CINV-000002 |
| `historical-incomplete-execution` | no terminal result and the invocation cannot safely resume | CINV-000001 |

**The category is checked against what the store holds.** Claiming a stranded
terminal result for an invocation with none is refused, and so is the reverse.

### No fabricated evidence

Abandonment writes no `CRES`. A synthesised success would be a lie; a
synthesised failure would close a question against the recovery enumeration
that could still have answered it. An existing result is referenced by
identity, never rewritten.

### Evidence

One `CADM` per accepted abandonment, in the namespace that already holds every
mutating verb to **intent, one attempt, outcome**:

```
execution/admin-records/CADM-NNNNNN/intent        verb=abandon, cinv
execution/admin-records/CADM-NNNNNN/abandonment   the administrative detail
execution/admin-records/CADM-NNNNNN/outcome       result=done
```

The `abandonment` member is new and create-once — the shape
`record_reconciliation` already uses. **No existing record schema changed.** It
carries cinv, previous_state, state, actor, request_id, recorded_at (ISO-8601
with offset, refused without one), reason, result_record_id, causal_references,
slot_released and its own cadm.

### Idempotency

An identical repeat reports `resumed: true`, releases no second slot and writes
nothing. A repeat differing in actor, request id, instant, reason or observed
result relationship **refuses** — a second authority for the same closure is a
decision nobody made. A lifecycle and an evidence record that disagree are
refused rather than reconciled.

---

## 5. GREEN evidence

`tests/test-capability-execution-abandonment.sh` — **25 PASS, 0 FAIL**, covering
every case the ruling required:

| | |
| --- | --- |
| blocker reproduced, and `launch_authorized -> released` refused | ✔ |
| `ABANDONED` distinct from `RELEASED`, terminal | ✔ |
| only `reserved` and `launch_authorized` may reach it | ✔ |
| occupancy excludes exactly `released` and `abandoned` | ✔ |
| abandon a stranded invocation with a provider-error CRES | ✔ |
| capacity 2/2 → 1/2 | ✔ |
| exact replay idempotent, no second transition record | ✔ |
| conflicting replay refuses | ✔ |
| CRES and CINV preserved byte-for-byte | ✔ |
| reason category must match the result relationship | ✔ |
| no result fabricated where none exists | ✔ |
| unknown invocation, bad actor, malformed request refused | ✔ |
| a `created` invocation is not administratively eligible | ✔ |
| CADM intent/abandonment/outcome, each create-once | ✔ |
| `abandon` carries no destruction authority | ✔ |
| no transition leaves `abandoned` | ✔ |
| an abandoned invocation cannot reacquire a slot | ✔ |
| `authorise-launch` reaches its refusal branch | ✔ |
| recovery no longer offers it as resumable | ✔ |
| a normal `RELEASED` lifecycle is unaffected and cannot be abandoned | ✔ |
| abandon both, 1/2 → 0/2, third reserves normally | ✔ |
| still bounded by `MAXIMUM_SLOTS` afterwards | ✔ |
| concurrent abandon + two reservations cannot oversubscribe | ✔ |

### Closed-set guards, updated rather than weakened

Four existing assertions failed on the change, which is them working:

| guard | change |
| --- | --- |
| capacity occupancy set | now the two-state exclusion, plus `SLOT_HOLDING_STATES` and `slot_holding_states()` |
| admin verb set | fourteen → fifteen; mutating thirteen → fourteen |
| admin destruction authority | **new** assertion that `abandon` is absent from `_DESTROYS_UNDER` |
| CLI verb set | `abandon` added, comment updated |

---

## 6. Two defects found by running it

**A wrong identity field, caught only by the production-copy rehearsal.** The
unit fixture called a result's identity `result_record_id`. That name exists —
it is what `InvocationDecision` carries — but the **record** field is
`capability_result_id`, which `identifiers.ID_FIELDS` states. The
implementation followed the fixture, every unit test passed, and the first
rehearsal against real records refused with *"terminal-result-lifecycle-stranded
asserts a terminal result and CINV-000002 has none"*.

That is the dangerous direction: a mis-named field makes an invocation with a
result look like one without, which is exactly the distinction the reason
categories turn on. Fixed by reading the field from `ID_FIELDS`, refusing a
bound result that carries no identity, and correcting the fixture — plus two
new cases asserting the fixture speaks the released schema, so it cannot drift
again silently.

**Two harness bugs**, both in the new suite: a `Manager` proxy created before
`fork` and unusable in the child, which read as a test crash rather than the
race it was meant to observe; and a source-text assertion against a string
literal that is wrapped across two lines in the source.

---

## 7. Rehearsals against a byte copy of production

No production state was touched. The scratch roots lived under `/data` so they
pass the same backing-store verification the real roots pass, and were removed.

### CINV-000002

```
starting state      launch_authorized       occupancy 2 of 2
cadm                CADM-000001
previous_state      launch_authorized   ->  abandoned
reason              terminal-result-lifecycle-stranded
result_record_id    CRES-000001             slot_released true, resumed false
occupancy           1 of 2
```

CINV-000001, CINV-000002, CINV-000003 and CRES-000001 all **byte-identical**
afterwards. CINV-000001 still `launch_authorized`. CINV-000003 still has no
execution state.

### CINV-000001

```
cadm                CADM-000002
previous_state      launch_authorized   ->  abandoned
reason              historical-incomplete-execution
result_record_id    null                    slot_released true
occupancy           0 of 2
result count        1, unchanged — nothing fabricated
```

### CINV-000003 Stage 2 capacity, on scratch only

```
reserve(CINV-000003) -> reserved        occupancy 1 of 2
```

The blocker is gone.

### The exact mutation

```
execution/admin-records/CADM-00000{1,2}/{intent,abandonment,outcome}
execution/transitions/CINV-000001.000003
execution/transitions/CINV-000002.000003
execution/mutations/CMUT-.../{intent,outcome}      the CMUT journal
execution/cadm-counter, execution/cmut-counter     advanced
```

`capability-invocation.seq` and `capability-result.seq` are **untouched**:
abandonment allocates from neither. The administrative and mutation journals
advance, which is the released contract for any administrative mutation.

### The ceremony block, rehearsed whole

Every gate and the closure itself ran against a production copy and produced
the reviewed verdict. A first attempt failed at the rc gate because the
rehearsal shim dropped the verb — the gate caught it and said *"STOP AND
REPORT"*, which is the behaviour it exists for.

---

## 8. The CINV-000002 reclamation ceremony

`provisioning/execution/g11-bc-v-cinv-000002-abandonment-ceremony.txt`.
Prepared, not performed. **CINV-000002 only** — CINV-000001 is a separate
ceremony and a separate authorisation.

**BLOCK A** observes containers as `kyri-capability` from `/tmp`, refuses a
`kyri-CINV-000002` container, and writes a witness. This matters more here than
elsewhere: abandoning an invocation removes it from the recovery enumeration, so
if a container could still exist this would close the one surface that would
have found it. The engine does not prove container absence — the operator does,
first.

**BLOCK B** contains no `sudo` and gates on the witness being under 900 seconds
old. It pins:

```
runtime baseline   6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f
CINV-000001        1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV-000002        923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
CINV-000003        c0941b7d45dcccac4bb28d00f942ea63aa90cd46ed55767797363f1ed1accaf2
CRES-000001        18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d
sequences          capability-invocation.seq 3, capability-result.seq 1
occupancy          2 of 2, held by CINV-000001 and CINV-000002
reason             terminal-result-lifecycle-stranded
expected after     abandoned, occupancy 1 of 2
```

Occupancy is read **through the released capacity model**, so "which states hold
a slot" is answered by `slot_holding_states()` rather than restated in the
ceremony. It proves CINV-000001 and CINV-000003 unchanged both before and after,
and ends by telling the operator to stop.

---

## 9. Verification

| | |
| --- | --- |
| `test-capability-execution-abandonment.sh` | **new** — 25 PASS, 0 FAIL |
| `capacity` / `capacity-race` / `lifecycle` / `admin` | 0 FAIL |
| `recovery-discovery` / `launch-bridge` / `launch-cli` | 0 FAIL |
| `mutation` / `quarantine` / `cleanup` / `protocol` / `quota` | 0 FAIL |
| `capability-runtime` / `invoke-preflight` / `authority-gate` | 0 FAIL |
| `trust-plane` / `test-static` / `test-docs-static` | 0 FAIL |
| ShellCheck | clean, exit 0 |

---

## 10. Actions NOT performed

```
production lifecycle                  NOT mutated
CINV-000001 abandonment               NOT performed
CINV-000002 abandonment               NOT performed
CINV-000003 Stage 2                   NOT run
Stage 3 / execute / payload           NOT run
CRES                                  NOT created
execution container                   NOT started
image store                           NOT modified
MAXIMUM_SLOTS                         UNCHANGED at 2
runtime files                         NOT hand-edited
reservations                          NOT deleted
CINV / CRES evidence                  NOT deleted
Fabric / Trust / Artifact authority   unaltered
Platform Evidence                     unaltered
Root Authority                        not mounted
ENG-0006                              not begun
```

Rehearsal scratch under `/data/kyri/g11bcv-*` was created outside every
governed store and removed.

## 11. Production no-mutation proof

```
/var/lib/kyri/fabric          a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5   unchanged
/data/kyri/capability-runtime 6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f   unchanged
capability-invocation.seq     3      capability-result.seq  1
CINV-000001 / 000002          still launch_authorized, occupancy 2 of 2
CINV-000003                   c0941b7d… unchanged, no execution state
admin-records                 empty; cadm-counter 000000
```

## 12. Known risks

**Abandonment removes an invocation from the recovery enumeration.** If a
container could still exist, the one surface that would have found it is closed.
The engine does not prove container absence; the ceremony does, and BLOCK A is
not optional.

**The witness is a record, not a lock.** It says the observation was made and
what it concluded, not that nothing has changed since. The 900-second bound
keeps the gap small.

**The state vocabulary grew.** A reader older than ADR-0015 refuses an
`abandoned` record as an unknown state rather than misreading it — the correct
direction, but it does mean a rollback of this code past a written abandonment
would make that invocation's chain unreadable.

**The authority lease may expire while this is reviewed.** CADV-000007 closes
`2026-09-23T06:00:00-05:00`. Per the checkpoint's own instruction that is
accepted: this design was not rushed to preserve it, and Stage 2 will
re-establish operational authority afterwards if needed.

## 13. Readiness

The architecture is implemented, documented in ADR-0015, and proved against
fixtures and against a byte copy of production. The first reclamation ceremony —
CINV-000002 only — is committed, gated, and rehearsed whole.

What remains is the reviewer's verification, and then a single operator
ceremony that closes one invocation and gives one slot back.
