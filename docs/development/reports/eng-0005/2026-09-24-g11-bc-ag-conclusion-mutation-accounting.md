# G11-BC-AG — the conclusion spent a CMUT, and my accounting said it would not

**Date:** 2026-09-24
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `84baeb71f4737a468c480e99b17108732b167fe1`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the mutation is correct and fully accounted for. The accounting that described it was wrong, and the error was mine.

---

## 1. The mutation was right. The accounting was not.

The closure ceremony asserted, as an **executable** check:

```
cmut-counter        MUST still be 000000000010
```

Production came back at `000000000011`. Nothing in production is wrong. What
was wrong is the expectation I wrote, and I wrote it in four places: the
ceremony, the G11-BC-AD report, a test suite that never looked, and an installer
check that proved the wrong half of the property.

**This is not a prose defect.** An executable ceremony assertion was false.

## 2. What the closure actually did

Verified read-only, then reconstructed by content.

| object | |
|---|---|
| `execution/transitions/CINV-000003.000003` | `{"cinv":"CINV-000003","previous":"launch_authorized","schema_version":1,"sequence":3,"state":"concluded"}` |
| `execution/mutations/CMUT-000000000011/intent` | `execution-transition`, target `CINV-000003.000003`, `expected_sha256 a154daa3…` |
| `execution/mutations/CMUT-000000000011/outcome` | `installed: true` |
| `execution/admin-records/CADM-000003/intent` | `verb=conclude`, `cinv=CINV-000003`, `target=null` |
| `execution/admin-records/CADM-000003/conclusion` | `derivation=reconstructed`, `handoff_retained=true`, `result_record_id=CRES-000002`, `slot_released=true`, `previous_state=launch_authorized`, `state=concluded` |
| `execution/admin-records/CADM-000003/outcome` | `result=done` |
| `execution/cadm-counter` | `000002 → 000003` |
| `execution/cmut-counter` | `000000000010 → 000000000011` |

`CMUT-000000000011`'s `expected_sha256` is `a154daa38eb58048a553ff6213214dd8639338da09e4e7013faddfbf186eb840`, and the
transition file hashes to exactly that. **CMUT000000000011_VERIFIED = PASS.**

### Reconstruction, by content

The objects were found empirically — every file modified at the closure
timestamp — not assumed. Removing exactly those six files and rewinding exactly
those two counters, in the store's own encoding, reproduces

`6757304ec093dd87c7aaeffeb14df729b01d3725210e932a42789c4801c01048`

the accepted pre-closure aggregate, **exactly**. Nothing unexplained.
**PRE_CLOSURE_RECONSTRUCTION = PASS.**

## 3. Why the CMUT is expected

`state._commit` — the single path **every** lifecycle transition takes — does
this:

```python
target = MutationTarget(kind=TargetKind.EXECUTION_TRANSITION, name=f"{cinv}.{sequence:06d}")
mutation = Mutation(root)
cmut = mutation.begin(target, schema_type="execution-transition",
                      expected_sha256=hashlib.sha256(body).hexdigest())
mutation.install(cmut, body)
mutation.commit(cmut)
```

A transition is *always* journalled through the T5 substrate. This is not
specific to a conclusion; `conclusion.py` is not unusual, and there is nothing
to fix in it.

**The store already proved it.** Every one of the eight transitions is named
1:1 by a CMUT:

| transition | CMUT | |
|---|---|---|
| CINV-000001.000001 / .000002 | 001 / 002 | |
| CINV-000002.000001 / .000002 | 004 / 005 | |
| **CINV-000002.000003** | **007** | the **abandonment** — the closest precedent to a conclusion |
| CINV-000003.000001 / .000002 | 008 / 009 | Stage 2 |
| CINV-000003.000003 | 011 | the conclusion |

G11-BC-AA's own report said *"every CMUT ever spent in this store is a Stage-2
transition, a Stage-2 authorisation, or the abandonment"* — a sentence that
states transitions spend CMUTs. I had that sentence, and the store, and wrote
the opposite anyway.

## 4. Root cause — four failures, none of them subtle

### 4a. The fixture was real. Nobody read it.

The conclusion suite **imports `CMUT_COUNTER`** and **creates `root/mutations`**.
The mutation substrate was live and unstubbed. It made **zero** CMUT assertions.

Driving the released `conclude` against that unmodified fixture, as written at
G11-BC-AD:

```
cmut-counter BEFORE conclude: 000000000002
cmut-counter AFTER  conclude: 000000000003
CMUTs: ['CMUT-000000000001', 'CMUT-000000000002', 'CMUT-000000000003']
```

**The evidence was one `print` away, in my own harness.** Not stubbed, not
injected, not hidden — simply never looked at.

### 4b. A case titled "no counter move" read one counter

```
run_case "a refusal writes nothing at all: no CADM, no transition, no counter move"
    counter = os.path.join(base, 'root', 'cadm-counter')
```

The `cmut-counter` is never opened. A refusal that spent a CMUT would have
passed this case.

### 4c. The ceremony hard-coded an assumption

`cmut-counter MUST still be 000000000010` was written from a belief about the
mutation shape, not derived from released code. The reviewer's instruction —
*the truthful expected mutation should be derived from released code, not
hard-coded from assumption* — names the defect exactly.

### 4d. The installer proved "one transition" and never its consequence

G11-BC-AF added a structural check that `conclude` writes **exactly one**
lifecycle transition. That check was correct and passed. It said nothing about
what a transition *costs*, so the whole verifier could be green while production
disagreed. **Proving a call count is not proving its journal consequence.**

## 5. Corrections

**No runtime source object changed** — all seven Generation-21 digests are
identical, and `conclusion.py`'s own docstring ("One transition,
`launch_authorized -> concluded`") was accurate and is untouched. ADR-0017 made
no CMUT claim and needed no correction.

| where | correction |
|---|---|
| closure ceremony | marked **SPENT**; the mutation shape now reads "one transition, its CMUT, and one CADM"; the measured table gains `cmut-counter 000000000010 → 000000000011` and lists all six created objects; the AFTER block now asserts `000000000011` and that CMUT-011 names `CINV-000003.000003`. **The wrong assertion is quoted in the header, not deleted.** |
| G11-BC-AD report | "One transition and one `CADM`" corrected in place, with the original wording preserved and the reason stated |
| conclusion suite | four new cases, **derived** from the substrate; the refusal case now reads both counters |
| Generation-21 installer | five new checks reading the consequence from `state._commit` |

### The new tests derive rather than declare

- a conclusion spends exactly one CMUT, and it names the transition just written;
- the CMUT pins the bytes that transition committed (`expected_sha256` vs the file);
- **the CMUT count tracks transitions one for one across the whole history**;
- the whole durable footprint is six files and two counters, proved by content.

The installer now proves `state._commit` opens a `Mutation`, drives it through
`begin`/`install`/`commit`, and names an `execution-transition` target — so
"one transition" entails "one CMUT" as a **property of the substrate**.
`--verify-source` now reports **45** properties, up from 40.

## 6. Two findings the checkpoint's premise did not have

### 6a. Generation 21 IS installed

The brief states *"Installed runtime: Generation 20"*. That is no longer true,
and could not be: `conclude` is a Generation-21 verb, so installation
necessarily preceded the closure.

All seven objects are at their Generation-21 digests, `conclusion.py` is
present, the library holds 84 `.py` objects (83 + 1 published helper), and
`capability --help` lists `conclude`.

Full `--verify-installed` **could not be run**: it reads
`/root/kyri-gen20-library-digests.txt`, which needs root. What is verifiable
unprivileged is confirmed above.

### 6b. Three spent ceremonies now pin a world that has moved on

**39 assertions across three suites**, from two causes — Generation 21 being
installed, and CINV-000003 being concluded:

| suite | failures | cause |
|---|---|---|
| Stage-3 rehearsal | 25 | 18 on the installed-generation gate (Generation-20 digests pinned), 7 knock-on |
| Stage-2 rehearsal | 9 | 1 generation gate, 8 because `CINV-000003 is concluded and is no longer awaiting launch authorisation` |
| CADM-000001 correction rehearsal | 5 | generation gate, and production now holds a third administrative record |

Every one is a ceremony correctly refusing a host it no longer describes.
**None was weakened.** Moving a ceremony to spent mode is a reviewed act —
G11-BC-AA treated it as one — and these three are outside this checkpoint's
scope, which is the CMUT accounting. They are reported for a reviewer decision.

### The Stage-3 self-check earned its keep

At G11-BC-AC I made the Stage-3 fixture rewind **checked, not trusted**, and
wrote: *"A future stage that writes something else makes this fail here rather
than pass quietly."* The conclusion was that stage. The rewind reported
`939a3660…` against the pinned `648066f6…` and **stopped**, instead of driving
161 assertions against a store that was not what it claimed. It is extended here
to subtract the closure as well, with the same check still proving the result.

## 7. Verification

| Run | Result |
|---|---|
| Conclusion suite | **33/33** (was 29; +4 mutation-accounting cases) |
| Mutation substrate suite | **38**, passing |
| Lifecycle / state suite | **45**, passing |
| Capacity suite | **31**, passing |
| Mutation-target-explicit suite | **32**, passing (rewind made derived) |
| Generation-21 `--verify-source` | **passed** — 45 properties |
| ShellCheck (CI-pinned 0.9.0) | clean, rc 0 |
| GitHub CI | **6/6 success** at `7f59a19` |
| `--verify-installed` | **not runnable** without root |
| Quick / full / clean-clone validators | **BLOCKED** at step 44, now on §6b rather than Fabric — the generation gate fires before the Fabric gate |

Fabric remains expired (`CADV-000007`, `2026-09-23T06:00:00-05:00`) and was
**not renewed**; no authority gate was weakened.

## 8. Production

**Unchanged by this checkpoint.** Nothing here mutated production; every
inspection was read-only and every reconstruction ran against a copy.

| | |
|---|---|
| Runtime aggregate | `4bb33d50c102c5af44d0b9e4faeaf198ed49c3a5391272516b516f0b8395651f` |
| `CINV-000003` | `concluded` · occupancy **1 of 2** |
| `CRES-000002` | `2d908b86…aebf`, unchanged |
| `cmut` / `cadm` / transitions | `000000000011` / `000003` / 8 |

## 9. What I got wrong, plainly

I asserted a mutation shape I had not measured, in an executable gate, against a
substrate whose behaviour was visible in three places I had already read: the
released `_commit`, the eleven CMUTs in the store, and my own fixture. The
ceremony gate is the one that mattered, because it was the artefact an operator
ran. The corrections above are aimed at the mechanism that let it through —
expectations are now derived from the substrate, and the installer proves the
consequence rather than the call count.
