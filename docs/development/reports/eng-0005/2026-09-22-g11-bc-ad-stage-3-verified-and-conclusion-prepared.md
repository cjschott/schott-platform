# G11-BC-AD — Stage 3 verified, and the closure the lifecycle never had

**Date:** 2026-09-22
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `422a45761c62da5fd153aac9c67a9ce956044023`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — Generation 21 is prepared and not installed. Production was not mutated.

---

## 1. Stage 3, verified independently

Read-only, measured against the installed Generation-20 runtime.

| | |
|---|---|
| Runtime aggregate | `6757304ec093dd87c7aaeffeb14df729b01d3725210e932a42789c4801c01048` — matches |
| Fabric aggregate | `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` — unchanged |
| `CRES-000002` | present |
| `capability-result.seq` / `capability-invocation.seq` | 2 / 3 |
| `cmut-counter` / `cadm-counter` | `000000000010` / `000002` |
| Transitions | 7 |
| `CRES-000003` | absent |
| `CINV-000003` | `launch_authorized` |
| Occupancy | **2 of 2** |

### Mutation accounting, by content

The aggregate is computed over paths as well as contents, so a copy at another
root cannot be compared directly. The method was validated first — an untouched
copy, with its paths rewritten to the production prefix, reproduces
`6757304e…1048` exactly — and only then applied.

Removing `capability-results/CRES-000002.yaml` and rewinding
`capability-result.seq` from `2\n` to `1\n` reproduces

`648066f6e79af23732eb6131bf772579bad898e71179def5ae4dabb6475e133a`

the accepted pre-Stage-3 aggregate, exactly. **Nothing unexplained.** (The first
attempt wrote `1` without the trailing newline and did not reproduce it; the
sequence file is two bytes, and that is the kind of difference this check
exists to catch.)

**STAGE3_VERIFICATION = PASS.**

## 2. The result, verified rather than accepted

Every field of `CRES-000002` matches what the reviewer reported:
`invocation_record_id: CINV-000003`, `outcome_class: completed`,
`attempt_number: 1`, `reason: null`, `result_artifact_reference: null`,
`schema_version: 2`, and `result_digest`
`sha256:fd2d58e99bae82f32ce320a3d3ac2a35b6e679b87432b2aedd9de1efa92cbad7`.

**The digest was recomputed, not compared.** The released package was run
against the published handoff payload (`591d4b0d…`, verified) and produced 281
bytes whose SHA-256 is `fd2d58e9…cbad7` — the value the record carries.

### Disposal, and the container

The governed Podman store cannot be read from the coordinator account, and it
did not need to be. `supervision.py` states the invariant:

> "A supervised execution that cannot prove its container is gone does not
> return a terminal outcome at all: it raises, so no `CRES` is written and the
> invocation stays unresolved for the readiness gate to find."

**The existence of `CRES-000002` is therefore itself the proof that no
`kyri-CINV-000003` container remains.** The closure ceremony observes the
container plane anyway, because that invariant licenses a claim about a
supervised execution and not about this host.

Separately: `/data/kyri/capability-handoff/CINV-000003/out` is now owned by
`kyri-capability` — direct evidence that §13's root-only ownership transfer
executed. That fact turns out to matter a great deal (§4).

**CRES000002_VERIFIED = PASS.**

## 3. The post-execution contract, proved from released code

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1 | Normal transition to a post-result state? | **NO** | `launch_authorized` goes only to `abandoned` or `created` |
| 2 | `CLEANED` reachable? | **NO** | `CleanupRefused: CINV-000003 is launch_authorized, and cleanup runs only from collected` |
| 3 | `RELEASED` reachable? | **NO** | only from `cleaned`; `capacity.release` additionally needs a `SlotReservation` |
| 4 | Can `recover` act? | **NO** | "advances no lifecycle, removes nothing, retries nothing" — it reported `CINV-000003` and wrote nothing |
| 5 | Can `cleanup` act? | **NO** | refused, as above |
| 6 | Can `execute` repeat? | **NO** | `TerminalResultExists: a terminal result already exists for CINV-000003 (CRES-000002, outcome completed)` |
| 7 | Does `ABANDONED` permit this state? | **YES** | `launch_authorized -> abandoned` is in the released table |
| 8 | Would abandoning misrepresent it? | **see §4** | |
| 9 | Missing "execution concluded" transition? | **YES** | |
| 10 | Architecture change required? | **YES** | |

**The decisive measurement.** An AST sweep of every `transition()` /
`transition_locked()` call site in the released package shows the only lifecycle
states any code writes are `LAUNCH_AUTHORIZED` (`launch.py`), `CLEANED`
(`cleanup.py`, only from `COLLECTED`), `RELEASED` (`capacity.py`, valid only
from `CLEANED`) and `ABANDONED` (`abandonment.py`). The eight intermediate
states are **never journalled by any code path**. Computing reachability from
`launch_authorized` using only states that can actually be written yields
exactly one destination:

```
table-reachable:                     abandoned, classified, cleaned, collected,
                                     container_verified, created, released,
                                     running, start_authorized, started, terminal
reachable using only writable states: abandoned
```

Two further findings, both load-bearing:

- **`cleaned` holds a slot.** Only `released` and `abandoned` do not. Reaching
  `cleaned` would not have returned the slot.
- **`CINV-000003` is not unresolved.** Its terminal result resolves it, so it
  does not block readiness — only `CINV-000001` does. Its cost is purely
  capacity.

## 4. The distinction, and why abandonment was not reused

`ABANDONED` means closure *"without asserting that the normal execution and
cleanup lifecycle completed"*, and ADR-0015 frames it for work that *"never ran
and never will"*. The reason category `terminal-result-lifecycle-stranded` fits
`CINV-000003` literally — a terminal result exists, the lifecycle never
advanced, capacity stayed held for an invocation already answered.

**The execution completed normally; the lifecycle failed to represent that
completion.** That is the distinction, and it is not what abandonment is for.

The decisive objection is structural rather than aesthetic. Because the
supervised path journals nothing past `launch_authorized`, **every successful
execution strands exactly like this one**. Abandonment as the standing answer
would record every success as `abandoned`, destroying the property ADR-0015
exists to create:

> "A stranded invocation is distinguishable from a completed one for ever."

**ABANDONMENT_SEMANTIC_FIT = AMBIGUOUS** — the category fits, the state's
meaning is lossy for a success, and using it as the general answer defeats the
ADR that defines it.

## 5. The approach that was tried first, and the defect it exposed

The first architecture chosen was to journal the progression the coordinator
drove (`created` → `collected`) and let the existing `cleanup` and
`capacity.release` finish. It was implemented in full and driven end to end
against a fixture, where it took `CINV-000003` to `released` and dropped
occupancy to 1 of 2.

**That fixture was lying.** The copy had silently omitted the output leaf,
because this account cannot read it. In production:

```
/data/kyri/capability-handoff/CINV-000003        uid=1000 gid=1000 mode=555
/data/kyri/capability-handoff/CINV-000003/out    uid=999  gid=987  mode=700
```

Against a faithful fixture, released `cleanup` refuses:

```
CleanupIncomplete: directory 'out' could not be opened as described:
[Errno 13] Permission denied: 'out'
```

and correctly leaves the invocation at `collected`.

**So `cleaned` is structurally unreachable for every supervised invocation, and
`released` with it.** §13 transfers the output leaf to the execution identity
and nothing in the released system removes it: the reconcile helper never
touches the handoff tree, there is no `tmpfiles.d` rule, and the only code that
touches `out` is the transition action that creates and chowns it. This is a
latent gap between §13 and the cleanup design — **not** a defect Stage 3
created, and not one this checkpoint repairs.

Running that approach in production would have journalled eight transitions and
still not closed the invocation, leaving it worse than it is now. It was
stopped, reported, and the architecture reconsidered.

## 6. Options, compared

| | truthful | evidence | slot | recovery | compat | generation | historical state | generalises |
|---|---|---|---|---|---|---|---|---|
| **`CONCLUDED`** (chosen) | yes — claims only what happened | `CRES` referenced, untouched | **released** | closed, never resumable | additive; older readers refuse an unknown state | 21 | nothing rewritten | **yes** |
| Governed `ABANDONED` | lossy — records a success as exceptional closure | preserved | released | closed | none needed | none | nothing rewritten | no — would abandon every success |
| Journal + existing verbs | would be truthful | preserved | **cannot reach** `released` | n/a | none | 21 | nothing rewritten | **impossible** — §5 |
| Full progression + privileged cleanup | fully truthful | preserved | released | closed | widens the privilege boundary | 21 + helper + sudoers | nothing rewritten | yes, at the largest risk |
| Leave stranded | fully truthful | preserved | **held** | unchanged | none | none | nothing rewritten | no — plane blocked at 2/2 |

**RECOMMENDED: `CONCLUDED`.** It claims exactly what happened and no more, adds
no privileged surface, needs no change to code the privilege boundary has just
exercised, and closes every future success automatically.

## 7. What was built

**ADR-0017**, and seven objects in one coherence group:

- `types.py` — appends `CONCLUDED`, off the linear order, behind `ABANDONED`;
- `state.py` — permits `launch_authorized -> concluded`, and nothing else
  reaches it; `concluded` is terminal;
- `capacity.py` — names it in `NON_SLOT_HOLDING_STATES`, which is the whole
  point of stating occupancy as an exclusion: a state added later holds a slot
  until somebody decides otherwise, and this is that decision;
- `recovery.py` — joins `_ADMINISTRATIVELY_CLOSED`, so it is never offered as
  resumable and is refused explicitly rather than by a positional lookup;
- `admin.py` — the closed-set `conclude` verb, absent from `_DESTROYS_UNDER`;
- `conclusion.py` — the operation;
- `cli.py` — `capability conclude`, and the inline closure after `execute`.

**One transition and one `CADM`.** The slot is released by the transition
itself. The `CADM` records `derivation` — `observed` inline, `reconstructed`
administratively — and `handoff_retained: true`, so the residue is stated rather
than implied.

**A defect of my own, found by the ordering analysis and fixed.** The inline
closure caught only `ValueError`. A half-published generation would have let an
`ImportError` turn a durable recorded result into a traceback. It now catches
broadly at that one call site, records the reason, and leaves the invocation
where `capability conclude` resumes it — the result stands whatever the closure
does.

## 8. The failure matrix

`tests/test-capability-execution-conclusion.sh` — **29 cases, all passing**.
Each sabotage reaches **its own** gate; a refusal for another reason would mean
the gate under test was never reached.

| condition | refusal |
|---|---|
| result missing | `has no terminal result; conclusion closes an execution that happened, and recovery answers one that did not` |
| wrong result identity | a result bound elsewhere is not this invocation's |
| more than one result | `more than one terminal result` — refused, not resolved |
| result with no identity | `carries no capability_result_id` — not read as absent |
| lifecycle not expected | `is reserved, and a conclusion closes an invocation at launch_authorized` |
| abandoned invocation | refused by state |
| no execution state | `has no execution state` |
| CINV changed | `is not a readable invocation` |
| conflicting closure | `carries a conclusion record while it is launch_authorized; the lifecycle and the evidence disagree` |
| concluded with no record | `concluded with no conclusion record` — a disagreement, not a resume |
| duplicate closure | resumes, releases no second slot, writes nothing |
| differing repeat | refused, **naming the field** that differs |
| capacity mismatch | cannot be manufactured: repeated calls never release a second slot |
| unverified root | refused before any read |
| naive/malformed instant | refused |
| uncontrolled derivation | refused |
| empty actor / request id | refused |
| **any refusal** | **writes nothing at all** — no `CADM`, no transition, no counter move |

Also proven: the module starts no process, deletes nothing, fabricates no
result and reads no clock; `conclude` carries no destruction authority; an error
outcome is concluded too, because the state is about the lifecycle and the
`CRES` is referenced rather than reinterpreted.

**Six closed-set guards across five suites caught the addition** — the occupancy
exclusion (twice), the verb set, the mutating-verb count, the lifecycle
vocabulary, the CLI verb list, and the purity-backstop registry. Each was
updated to the new **exact** set rather than loosened. ADR-0017 is the review
those sets exist to require.

## 9. Generation 21

`provisioning/execution/install-generation-21.sh`, prepared and **not run**.
`--verify-source` passes: *"all checks passed. 7 object(s) would change (6
REPLACE, 1 CREATE)"*, with Generation 20's carried-forward assertions still
holding — ADR-0015 intact, `MAXIMUM_SLOTS` still 2.

**Publication order was measured, not inherited.** Every intermediate was run by
importing `tools.capability.cli` against it:

```
published so far                              imports   conclude verb
(Generation 20)                               yes       no
+ types, state, capacity, recovery, admin     yes       no
+ conclusion                                  yes       no
+ cli  (Generation 21)                        yes       YES
```

No intermediate can close an invocation: `types.py` adds a name no transition
reaches, `state.py` permits a transition nothing calls, `capacity.py` excludes a
state that cannot yet exist, `recovery.py` closes a state nothing can be in,
`admin.py` adds a verb nothing can reach, and `conclusion.py` is unreachable
until a surface names it.

**The reverse order fails differently from Generation 20's, and worse.**
`cli.py` imports `conclusion` **lazily**, so publishing it first does not fail
closed at import — it exposes a `conclude` verb that raises `ImportError` when
used, and `execute` would record a durable result and then raise from the inline
closure. `conclusion.py` before `cli.py` is what makes that unreachable, and
rollback restores in reverse.

The installer's own gate caught a real inconsistency during preparation: the
declared publication order still named Generation 20's five objects, and it
refused to publish seven rows against five stated positions.

**The G5 preflight was updated too.** Each REPLACE row gains the digest the host
is installed *at* on the baseline side and the digest it moves *to* on the
successor side, and `conclusion.py` is declared as this generation's CREATE.
Without that the preflight reports reviewed source as drift — which it did, and
which is how the omission was found.

## 10. The ceremonies

- `provisioning/execution/gen21-operator-ceremony.txt` — installs seven objects
  and **closes nothing**. Occupancy stays 2 of 2 across the publication.
- `provisioning/execution/g11-bc-ad-cinv-000003-closure-ceremony.txt` — three
  blocks, as at Stage 3. BLOCK A observes the container plane and writes a
  witness under 900 s old. BLOCK B pins the seven installed Generation-21
  digests, the runtime and Fabric aggregates, `CRES-000002` **by content**, both
  sequences, both counters, the transition count, the lifecycle and occupancy
  2 of 2. BLOCK C is the single command, with `--store-root` explicit and no
  default.

It states the three things it does not do — no result written, no cleanup
claimed, no container touched — and states the residue rather than leaving it to
be discovered.

## 11. Capacity

| invocation | state | holds a slot |
|---|---|---|
| `CINV-000001` | `launch_authorized` | **yes** |
| `CINV-000002` | `abandoned` | no |
| `CINV-000003` | `launch_authorized` | **yes** |

Under the recommendation, `CINV-000003`'s slot is released by the `concluded`
transition itself, taking occupancy to **1 of 2**. `CINV-000001` was **not**
reclaimed and cannot be concluded: it has no terminal result, so `conclude`
refuses it by construction, and it remains in the recovery enumeration.

## 12. Verification

VERIFICATION_PLACEHOLDER

## 13. Production

| | before | after |
|---|---|---|
| Runtime aggregate | `6757304e…1048` | `6757304e…1048` |
| Fabric aggregate | `a87c2010…12e5` | `a87c2010…12e5` |
| `CRES-000002` | `2d908b86…aebf` | `2d908b86…aebf` |
| `CINV-000003` | `launch_authorized` | `launch_authorized` |
| Occupancy | 2 of 2 | 2 of 2 |
| Transitions / `cadm` | 7 / `000002` | 7 / `000002` |

The **installed runtime was not modified**: `cli.py` is still the Generation-20
`90979a02…`, and `conclusion.py` is not installed. Generation 21 exists in the
checkout and nowhere else.

## 14. Actions not performed

`CINV-000003` was not concluded, abandoned, cleaned up or recovered in
production. `execute` was not re-run. `CINV-000001` was not reclaimed. No result
evidence was altered. `MAXIMUM_SLOTS` is unchanged at 2. Fabric, Trust, Artifact
authority and Platform Evidence were not altered. Root Authority was not
mounted. Generation 21 was **not installed**. ENG-0006 was not begun.

## 15. For the reviewer

Stage 3 is verified and its accounting is complete. The lifecycle gap it exposed
is general, not particular to `CINV-000003`, and the recommended closure is the
narrowest truthful one available without touching the privilege boundary.

Two things are deliberately left open:

1. **The handoff residue.** Every concluded invocation leaves its subtree on
   disk, and nothing can remove it. Repairing that means either returning the
   output leaf at §13 or adding a privileged removal — a decision this
   checkpoint declines to take for the reviewer.
2. **`CINV-000001`.** Still `launch_authorized` with no result, still holding a
   slot, still the only invocation blocking readiness.
