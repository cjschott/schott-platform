# G11-BC-AE — ADR-0017 accepted, the installer made truthful, and an authority that lapsed

**Date:** 2026-09-23
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `593764eb038e70553114194b4e5eae0dea1fa885`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the three corrections are complete. **`CADV-000007` expired at 06:00 today**, which blocks local validation and, more importantly, blocks Stage-3-class ceremonies. Renewal is not taken here.

---

## 1. The three corrections

### 1. ADR-0017 status

```
- **Status:** Accepted
- **Date:** 2026-09-22
- **Accepted:** 2026-09-23, at G11-BC-AE
```

Architectural content unchanged. The acceptance date is recorded as its own
field rather than by overwriting the authored date, so the two facts stay
distinguishable.

### 2. The CREATE-count prose

The installer carried, immediately above the two constants that contradict it:

> `No CREATE, so the count does not move.`

That was Generation 20's sentence and it was false here. It now reads:

> `ONE CREATE, so the count moves by one: conclusion.py does not exist at
> Generation 20.`

`EXPECTED_LIBRARY_FILES_BASELINE=82` and `EXPECTED_LIBRARY_FILES_TARGET=83`
were already correct and are **unchanged**.

### 3. The coherence-group diagnostic

`group_name P` reported `provenance correction and explicit mutation targets`.
It now reports:

```
post-execution lifecycle conclusion
```

Verified by calling the function. Group membership and publication order are
untouched.

### 4. A fourth instance of the same defect, corrected and flagged

Correction 2 is a symptom of something larger sitting directly above the
matrix. The block introducing it described **"the five generation-20 objects"**
and explained group P in terms of `backing_store.py`, `abandonment.py` and
`provenance.py` — **none of which Generation 21 publishes** — together with
Generation 20's `target_fingerprint` and `Verb.CORRECT_PROVENANCE` failure
reasoning.

That is the same class as correction 2, in the same file, and it contradicted
the matrix immediately below it. It is corrected under "fix only what is
required to restore truthful validation" and is reported here rather than
folded in silently.

It now describes the seven objects this generation publishes and each distinct
way a subset breaks — an `AttributeError` on `LifecycleState.CONCLUDED`, an
occupancy answer that is *wrong rather than an error*, a positional lookup
falling through for a state off the linear order, an `AttributeError` on
`Verb.CONCLUDE`, and the lazy `ImportError` that **does not land until the verb
is used**, which is exactly why publication order puts `conclusion.py` first and
`cli.py` last.

## 2. Reverify — every item the ruling asked for

| Requirement | Result |
|---|---|
| Runtime source target digests unchanged | **identical**, all seven, byte-compared before and after |
| `COMMIT` remains `0bd3b8ac…7c78` | unchanged |
| Matrix remains 7 objects | 7 rows |
| 6 REPLACE / 1 CREATE | 6 / 1 |
| Library count 82 → 83 | unchanged |
| Publication order | `types, state, capacity, recovery, admin, conclusion, cli` |
| `conclusion.py` absent from installed runtime | **absent** |
| Generation 21 installed | **NO** — installed `cli.py` is still Generation 20's `90979a02…` |
| Production runtime aggregate | `6757304ec093dd87c7aaeffeb14df729b01d3725210e932a42789c4801c01048` |
| `CINV-000003` | `launch_authorized` |
| `CRES-000002` | `2d908b86…aebf`, exact |
| Occupancy | **2 of 2** |

The diff is two files and nothing else: the ADR header, and installer prose.

```
docs/decisions/ADR-0017-post-execution-lifecycle-conclusion.md |  3 +-
provisioning/execution/install-generation-21.sh                | 51 +++++++----
```

## 3. `CADV-000007` has expired

**This is the finding of this checkpoint, and it is not caused by its edits.**

```
now                     2026-09-23T06:53:35-05:00
CADV-000007 valid_until 2026-09-23T06:00:00-05:00

released verifier: supported = False, reason = admission-window-not-open
```

The authority lapsed 53 minutes before it was measured. G11-BC-AB had recorded
the window closing today and ruled: *"If it has expired or authority has moved:
STOP. Do not renew authority in this checkpoint."* Altering Fabric is a standing
STOP boundary. **It was not renewed.**

### What it blocks

| suite | failures | cause |
|---|---|---|
| Stage-2 rehearsal | 1 | the spent ceremony now refuses at the authority gate rather than on the durable store fact the assertion names |
| Stage-3 rehearsal | 22 | BLOCK B asks the released verifier at run time, and it refuses |

**23 assertions, one cause.** Every other Fabric-gated suite passes —
advertisement preflight, invoke preflight, capability fabric, operation
authority, admission dependency bound, the CROUTE-0006 freeze rehearsal and the
invoke E2E are all green.

### Proved independent of this checkpoint

The same two suites were re-run at `593764e` — yesterday's fully green commit,
with none of today's edits present:

```
at 593764e:  stage-2 FAIL=1   stage-3 FAIL=22
at 97486c0:  stage-2 FAIL=1   stage-3 FAIL=22
```

Identical. The cause is the clock, not the corrections.

### Why these assertions were not adjusted

Both failures are the gates **working**. The Stage-3 rehearsal drives BLOCK B,
whose entire purpose is to ask the released verifier at the moment it runs and
refuse if authority has lapsed — the check that would stop a production Stage 3
on expired authority. Broadening it to accept the expiry would invert the
assertion into one that passes when the thing it guards against is true.

The Stage-2 assertion is narrower but the same shape: it requires the spent
ceremony to refuse **on a durable fact** — that the store moved past it —
specifically so that a refusal for some other reason is not mistaken for
spentness. An earlier gate now fires first. Accepting that as spentness would
be the "refused for another reason" case the assertion exists to catch.

Neither is weakened here. **Renewal is a reviewer decision; a green validator
bought by loosening the authority gates is not.**

## 4. Verification

| Run | Result |
|---|---|
| Generation-21 `--verify-source` | **passed** — 7 objects (6 REPLACE, 1 CREATE) |
| `group_name P` | `post-execution lifecycle conclusion` |
| Conclusion suite | **29/29 PASS** |
| Stage-0 / Stage-1 rehearsals | 15 / 26, passing |
| Other Fabric-gated suites (7) | all passing |
| ShellCheck (CI-pinned 0.9.0) | clean, rc 0 |
| GitHub CI | **6/6 success** at `97486c0` |
| Quick validator | **BLOCKED** at step 44 — Stage-2 rehearsal, expired authority |
| Full validator | **BLOCKED** — same cause |
| Clean-clone validator | **NOT RUN** — it would fail identically; the clone reads the same production Fabric |

CI is green because the expiry is a production-side condition and the affected
suites are host-only: off this host they skip for a stated reason. That is the
correct asymmetry and not a reason to treat the host result as noise.

## 5. Production

Unchanged throughout. Nothing in this checkpoint touched it.

| | |
|---|---|
| Runtime aggregate | `6757304e…1048` |
| `CRES-000002` | `2d908b86…aebf` |
| `capability-result.seq` / transitions / `cadm` | 2 / 7 / `000002` |
| `CINV-000001` / `-000002` / `-000003` | `launch_authorized` / `abandoned` / `launch_authorized` |
| Occupancy | 2 of 2 |
| Installed runtime | Generation 20; `conclusion.py` absent |

## 6. Actions not performed

Generation 21 was not installed. `CINV-000003` was not concluded. Runtime
semantics were not changed — no runtime source object moved. **Fabric authority
was not renewed and no Fabric record was altered.** No assertion was weakened to
make validation green. `CINV-000001` was not reclaimed. `MAXIMUM_SLOTS` is
unchanged at 2. ENG-0006 was not begun.

## 7. For the reviewer

The three corrections are done and the installer now describes the matrix it
actually carries. Generation 21 is ready for operator publication on its own
terms: `--verify-source` passes, the digests are untouched, and CI is green.

**One decision is needed before that, and it is not mine.** `CADV-000007`
expired this morning. Until authority is renewed:

- local validation cannot be green, because two suites correctly refuse;
- and more materially, **the Generation-21 operator ceremony and the
  CINV-000003 closure ceremony are unaffected** — neither is gated on Fabric
  authority, because neither executes a capability. Installation and closure can
  proceed on expired authority; what cannot proceed is any further *execution*.

So the reviewer has two independent questions: authorise Generation-21
installation, and separately decide whether to renew `CADV-000007` — which
G11-BC-AB reserved for a checkpoint of its own.
