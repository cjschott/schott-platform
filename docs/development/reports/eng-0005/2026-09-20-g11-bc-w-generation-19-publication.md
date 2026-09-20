# G11-BC-W — Generation 19 prepared, before its authority is used

ENG-0005. 2026-09-20. Branch `arch/eng-0005-execution-transition`.

The reviewer refused the G11-BC-V CINV-000002 reclamation ceremony on
runtime-generation coherence. **The refusal was right, and the consequence was
worse than a coherence violation.** §3 proves it.

The G11-BC-V architecture is unchanged and still accepted. What this checkpoint
adds is the publication that has to come first: a Generation-19 installer built
on the established mechanism, its operator ceremony, and a fixture-driven suite
that proves both the bytes and the semantics. The old ceremony is withdrawn.

Nothing was installed. Production is byte-identical.

---

## 1. Source and live authority

| | |
| --- | --- |
| HEAD at start | `5ab509125963c2b8862815aba6f6ee6b878d0d92` ✔ |
| branch / origin / tree | `arch/eng-0005-execution-transition`, clean ✔ |
| CINV-000001 | `launch_authorized` ✔ |
| CINV-000002 | `launch_authorized` ✔ |
| CINV-000003 | no execution state ✔ |
| occupancy | 2 of 2 ✔ |
| `capability-invocation.seq` / `capability-result.seq` | 3 / 1 ✔ |
| runtime baseline | `6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f` ✔ |
| ABANDONED records in production | none; `admin-records` empty, `cadm-counter` 000000 ✔ |

## 2. The declaration, and that it is not installed

Read from the committed generation mechanism
(`provisioning/execution/g5-preflight.sh`). All seven objects are declared, all
seven checkouts match their declared successors, and **none is installed**:

| object | op | installed (Gen 18) | declared successor |
| --- | --- | --- | --- |
| `execution/types.py` | REPLACE | `7dc35046…` | `da2e01f9…` |
| `execution/state.py` | REPLACE | `f0b00112…` | `88b05c07…` |
| `execution/capacity.py` | REPLACE | `25bab08c…` | `f037119f…` |
| `execution/recovery.py` | CREATE¹ | `fdad3cec…` | `d044cb29…` |
| `execution/admin.py` | REPLACE | `be899d7a…` | `2dbc2941…` |
| `execution/abandonment.py` | CREATE | **ABSENT** | `4fb431ca…` |
| `cli.py` | REPLACE | `7b4fac3e…` | `a350b788…` |

¹ `recovery.py`'s declaration row is a CREATE from its original generation and
has accumulated successors since; the installed object is its last one.

**Objects at Generation 19: 0 of 7.** `INSTALLED=NO`.

---

## 3. Why the reviewer was right, proved

The withdrawn ceremony would have run `capability abandon` out of the checkout
against the production runtime. Asked directly, the **installed** runtime:

```
installed LifecycleState members: 12
installed has ABANDONED: False
installed reader REFUSES 'abandoned': 'abandoned' is not a valid LifecycleState
installed has NON_SLOT_HOLDING_STATES: False
```

And a Generation-18 read of the chain that write would have produced:

```
Generation-18 read FAILS: StateIntegrityFailure: CINV-000002.000003 names an unknown state
```

**The blast radius is the whole store, not one invocation.** `all_states`
resolves every chain inside a single comprehension:

```python
return {cinv: _resolve(records, cinv)[0]
        for cinv, records in _scan(root).items()}
```

so one unreadable record raises out of it for every caller. In the installed
runtime those callers are `capacity.reserve` (twice), `recovery` and `cleanup`.
The installed execution plane would have stopped working entirely — and the
reclamation the ceremony existed to perform would have been the thing that
broke it.

I did not see this in G11-BC-V. I checked that the ceremony would run, not
which runtime it would run *against*.

---

## 4. The Generation-19 installer

`provisioning/execution/install-generation-19.sh`, built from
`install-generation-18.sh` — the established mechanism, not a special path.
Same five modes (`--verify-source`, `--verify`, `--install`,
`--verify-installed`, `--recover`), same transaction journal, same `--fixture`
harness.

- **Pinned authority** `5ab509125963c2b8862815aba6f6ee6b878d0d92`, with
  `GEN18_COMMIT` set to the real Generation-18 authority
  `88a1e484f063ad0c4bb5d05ddac6de2df623491c` and checked to be its ancestor.
- **One coherence group, B.** No partial publication is representable:
  `require_group_coherence` refuses a committed state holding some members at
  each generation.
- **One CREATE.** `abandonment.py` declares `ABSENT` as its predecessor, the
  library grows 80 → 81, and rollback deletes rather than restores.

### The publication order was measured, not inherited

Generation 18's order came from one import edge between two objects. That
reasoning does not transfer to seven, so every intermediate was run:

```
published so far          tools.capability.cli   abandon verb reachable
------------------------  ---------------------  ----------------------
(Generation 18)           imports                no
+ types                   imports                no
+ state                   imports                no
+ capacity                imports                no
+ recovery                imports                no
+ admin                   imports                no
+ abandonment             imports                no
+ cli  (Generation 19)    imports                YES
```

**The second column is the one that matters.** Every intermediate imports — but
more importantly, none can reach the abandon verb, so **no intermediate can
write an ABANDONED record** and no Generation-18 reader is ever shown a state
it cannot parse, at any point during the publication.

The reverse order was measured too:

```
cli.py first -> ModuleNotFoundError: No module named 'tools.capability.execution.abandonment'
```

on every command, including `recover` — the one an operator needs to resolve an
interrupted transaction. Fail-closed for the recovery surface is worse, not
better.

`require_fail_closed_first` now holds the **whole order** as a checked property
rather than the two ends only, and `rollback` restores in reverse.

### The correction, proved from the reviewed bytes

`--verify-source` proves each property where it is decided, not by the presence
of a word:

```
ok  the reviewed types.py declares ABANDONED alongside RELEASED, not instead of it
ok  the reviewed state.py reaches ABANDONED only from reserved and launch_authorized, and never leaves it
ok  the reviewed capacity.py keeps MAXIMUM_SLOTS at 2 and excludes only RELEASED and ABANDONED
ok  the reviewed recovery.py refuses ABANDONED explicitly, not by an index lookup that happens to raise
ok  the reviewed admin.py adds ABANDON to the closed set with no destruction authority
ok  the reviewed abandonment.py allocates no identity, deletes nothing, and names its eligible states
ok  the reviewed cli.py exposes abandon with a closed reason set and no target-state flag
```

The state check reads the transition relation itself and refuses **each of the
ten states past the handover** individually, so a row added later cannot quietly
grant one of them an edge into ABANDONED.

Generation 18's four checks are kept and relabelled **carried forward**:
`evidence.py` and `coordinator.py` do not move here, so they now prove that
correction has not regressed under this one.

---

## 5. Installed-generation semantics, not just hashes

`tests/test-capability-execution-generation19-installer.sh` — **137 PASS, 0
FAIL**. It reconstructs the Generation-18 baseline from git, drives the real
installer through every mode against a fixture, and then asks the **installed
fixture library** — not the checkout — the semantic questions:

```
ABANDONED parses                                              ✔
launch_authorized -> ABANDONED legal, reserved -> ABANDONED   ✔
ABANDONED has no outgoing transition                          ✔
ABANDONED consumes no slot; RELEASED consumes no slot         ✔
every other state consumes one; MAXIMUM_SLOTS == 2            ✔
an unknown FUTURE state is NOT in the exclusion set:
  it would hold a slot, which is the fail-safe direction      ✔
recovery does not enumerate ABANDONED as resumable            ✔
capability abandon available, reason constrained to the set   ✔
no --force / --to / --state / --target-state; verb set closed ✔
ABANDON carries no destruction authority                      ✔
```

**With a control**, so the case measures this generation rather than passing
regardless: the Generation-18 fixture library knows nothing of ABANDONED, has
no exclusion set, and exposes no `abandon` verb.

**And the coherence argument itself is a test**: the Generation-18 fixture
reader is handed an `abandoned` chain and must refuse it. If it ever stopped
refusing, the reason this generation had to come first would have evaporated,
and the suite would say so.

The interruption matrix runs all ten failure points and proves
`UNSAFE_MIX_REACHABLE=NO`; the count assertion now accepts baseline (rolled
back) or baseline+1 (committed), because this generation creates one object.

---

## 6. The operator ceremony

`provisioning/execution/gen19-operator-ceremony.txt`. Refuses on transaction
residue before any installer runs, requires the Generation-18 evidence, then
`--verify-source → --verify → --install → --verify-installed`, chained so a
refusal stops everything.

It states plainly what it does **not** do: it abandons nothing, writes no
lifecycle record, closes no invocation, and leaves occupancy at 2 of 2. It
publishes the ability to reclaim a slot and performs none of it.

**`--verify` and `--install` require root** — they read
`/root/kyri-gen18-library-digests.txt`, which this session cannot. That is the
review boundary, and it is where this checkpoint stops.

---

## 7. The withdrawn ceremony

`provisioning/execution/g11-bc-v-cinv-000002-abandonment-ceremony.txt` is now a
tombstone: it refuses before reaching any command, states why, names its
replacements, and exits 1.

It is **kept, not deleted**. Its gates, pins and rehearsal are what the
regenerated ceremony will be built from, and deleting it would delete that
evidence. What was wrong was the sequence, not the architecture.

The regenerated CINV-000002 ceremony will be prepared **after** Generation 19 is
installed and independently verified, and revalidated against the then-current
runtime baseline, immutable record digests, lifecycle states, capacity occupancy
and container absence. It will call the installed runtime authority rather than
importing unpublished checkout code.

---

## 8. Verification

| | |
| --- | --- |
| `test-capability-execution-generation19-installer.sh` | **new** — 137 PASS, 0 FAIL |
| `test-capability-execution-generation18-installer.sh` | 0 FAIL |
| `test-capability-execution-abandonment.sh` | 0 FAIL |
| `capacity` / `admin` / `lifecycle` / `recovery-discovery` | 0 FAIL |
| `launch-cli` / `mutation` / `capability-runtime` / `execution` | 0 FAIL |
| `test-static.sh` / `test-docs-static.sh` | 0 FAIL |
| ShellCheck | clean, exit 0 |
| `install-generation-19.sh --verify-source` | all checks passed, 7 objects (6 REPLACE, 1 CREATE) |

## 9. Actions NOT performed

```
Generation 19 installation           NOT performed (root; operator action)
CINV-000001 / CINV-000002 abandon    NOT performed
CINV-000003 Stage 2 / Stage 3        NOT run
an ABANDONED production record       NOT created
lifecycle state                      NOT altered
CADM abandonment evidence            NOT created
CINV / CRES records                  unaltered
invocation / result sequences        unchanged (3 / 1)
MAXIMUM_SLOTS                        unchanged at 2
Fabric / Trust / Artifact authority  unaltered
Platform Evidence                    unaltered
Root Authority                       not mounted
ENG-0006                             not begun
```

## 10. Production no-mutation proof

```
/data/kyri/capability-runtime  6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f  unchanged
/var/lib/kyri/fabric           a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5  unchanged
installed library              81 .py objects, still Generation 18
installed LifecycleState       12 members, no ABANDONED
CINV-000001 / CINV-000002      launch_authorized, occupancy 2 of 2
```

## 11. Known risks

**The fixture is not the host.** The suite reconstructs the Generation-18
surface from git and drives the installer against it. What it cannot exercise
is the real `/root` evidence, the real 0444 installs as root, and the real
transaction directory. Those are first exercised in the operator ceremony,
which is why `--verify` runs before `--install` and `--recover` exists.

**One generation, two reviews.** Installing Generation 19 does not authorise
any abandonment. The regenerated CINV-000002 ceremony is a separate preparation
and a separate review, against a baseline that this installation will move.

**The authority lease may expire.** CADV-000007 closes
`2026-09-23T06:00:00-05:00`. Per G11-BC-V's instruction that is accepted; Stage
2 will re-establish operational authority afterwards if needed.

## 12. Readiness

Generation 19 is declared, its installer is built on the established mechanism
and proved against a fixture through every mode, its semantics are proved
against the installed library with a control, and the reason it must precede any
abandonment is itself a test.

What remains is the reviewer's verification of the publication authority, and
then a single operator run of the Generation-19 ceremony — which installs seven
objects and abandons nothing.
