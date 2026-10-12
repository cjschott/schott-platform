# G11-BC-AF — the Generation-21 installer now proves the generation it publishes

**Date:** 2026-09-23
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `f4250bc8c35090b28f8c50a06ba8d526bcd1cb97`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — installer verification corrected. No runtime source object changed. Generation 21 is **not** installed.

---

## 1. The finding, confirmed

The matrix and prose described Generation 21; the `--verify-source` **body**
still largely proved Generation 20. Under the heading *"THE CORRECTION THIS
GENERATION EXISTS TO DEPLOY"* it asserted `target_fingerprint` in
`backing_store.py`, eight properties of `provenance.py`, and the internals of
`abandonment.py` — **three files this matrix does not publish.**

That is not a cosmetic problem. An installer that verifies another generation's
purpose is an installer whose green verdict means something other than what it
says.

## 2. Inventory, classified

### Class 2 — stale generation-purpose checks: **15 removed**

Every one names a file Generation 21 does not publish, so asserting its
internals here claimed an authority this matrix does not have. Generation 20's
purpose was proved when Generation 20 was accepted, and its evidence lives in
that ceremony.

| file | checks removed |
|---|---|
| `backing_store.py` | 3 — defines `target_fingerprint`, stats the descriptor, `RootDescriptor` carries no path |
| `provenance.py` | 9 — forbidden reaches, correctable set, lifecycle claims, `CINV` lock, opens nothing for writing, digests its subject, states non-reversal, states retention, fingerprints its root |
| `abandonment.py` | 3 — eligible states, allocates/deletes nothing, fingerprints its root |

### Class 1 — legitimate carried-forward invariants: **16 retained**

Retained **only** where a file *this* generation republishes carries them, and
relabelled `regression:` so none reads as this generation's purpose:

- **`admin.py`** (moves) — the closed verb set still holds `ABANDON` and
  `CORRECT_PROVENANCE`, and **no** closure verb — now including `CONCLUDE` —
  appears in `_DESTROYS_UNDER`.
- **`cli.py`** (moves) — the 2026-09-20 root cause: all **three** administrative
  mutators require an explicit `--store-root`, `_explicit_root` exists, the
  compiled-in root is resolved exactly 3 times, neither `command_abandon` nor
  `command_correct_provenance` can reach it, no `--force`/`--to`/`--target-state`
  flag exists, and all three verbs are exposed.
- **`types.py` / `capacity.py`** (both move) — ADR-0015 intact: `ABANDONED`
  alongside `RELEASED`, `MAXIMUM_SLOTS` still 2.

The Generation-18 `coordinator.py` / `evidence.py` regressions were already
labelled as such and are kept: Generation 21 adds an inline closure to
`command_execute` that runs *after* `execute_supervised`, so the
gate-before-provider ordering those checks prove is a precondition this
generation's new code depends on.

### Class 3 — stale diagnostic/comment only

Corrected at G11-BC-AE (group name, CREATE-count prose) and here
(`verify-installed` commentary, transaction identity).

## 3. What replaced it: ADR-0017, proved structurally

`--verify-source` now reports **40 properties** proved from the reviewed bytes.
The reviewed sources are staged from `${COMMIT}` and **parsed** — never
imported, because importing would run them.

Structural where a grep would be too weak:

- **The transition relation is compared as a whole**, not searched for a word.
  The entire `_ALLOWED` table is reconstructed from the AST and compared against
  the accepted one, so *"`launch_authorized` gains `concluded` and no other edge
  anywhere changes"* is a single assertion.
- **The linear progression is checked for insertion**, because declaration order
  is read positionally when a transition is validated.
- Occupancy exclusion, recovery closure, the verb set and the destruction
  mapping are read from the parsed source.
- `conclude` must write **exactly one** lifecycle transition, and it must be the
  one into `CONCLUDED` — which is what releases the slot, so there is no
  separate release step to forget.
- It must allocate **exactly one** `CADM`, record `handoff_retained` true, and
  name **neither** `CLEANED` nor `RELEASED` nor `ABANDONED`.
- Both callers must reach the **same primitive**; the inline one must record
  `derivation=observed` and the operator one `reconstructed`.
- The result must be recorded **before** the closure, the failure must be caught
  and reported, and the invocation reported as still `launch_authorized` —
  slot-holding, never falsely marked concluded.

### The verifier was negative-tested

A verifier that only ever passes proves nothing. Nine sabotages were applied to
staged copies of the reviewed source; **all nine were caught, each by its own
check**:

| sabotage | caught by |
|---|---|
| `CONCLUDED` removed from `types.py` | declares CONCLUDED |
| an extra edge added to the relation | the relation is exactly the accepted one |
| `CONCLUDED` made slot-holding | capacity excludes exactly three states |
| `MAXIMUM_SLOTS` raised to 4 | MAXIMUM_SLOTS remains 2 |
| recovery would resume it | administratively closed |
| `CONCLUDE` granted destroy rights | carries NO destruction authority |
| `conclude` fabricates a result | never fabricates a result |
| `conclude` writes a second transition | exactly ONE transition |
| `handoff_retained` flipped to false | recorded rather than implied |
| `conclude` claims `RELEASED` | the one transition is into CONCLUDED |
| closure moved **before** the result | the result is recorded BEFORE the closure |

Two sabotages initially failed to fire. **Both were weak sabotages, not weak
checks** — one inserted a bare name rather than a call, the other used the wrong
indentation so the substitution never applied. They were corrected rather than
recorded as passes.

Two checks initially failed against correct source: `ast.unparse` normalises
quotes, so matching `"handoff_retained": True` never matched `'handoff_retained':
True`. Both were made **structural** — walking dict literals — rather than
adjusting the quoting, so they no longer depend on how the printer formats.

## 4. `--verify-installed`, corrected

It claimed:

> `verify_unchanged_surface` judges cli.py because it is NOT a matrix target

**`cli.py` IS a matrix target in this generation**, and that function begins
`is_target "${file}" && continue` — it *skips* targets. The comment described
the opposite of what runs, and cited a coherence group (`R`) this generation
does not have.

It now states the real division: `verify_installed_set` judges the seven matrix
targets against the reviewed Generation-21 digests — **every target being at its
target digest is what "no mixed-generation publication" means**, because a
half-published matrix leaves at least one at its Generation-20 digest and fails
there — while `verify_unchanged_surface` judges everything else.

Three new structural proofs, wired into every read-only mode:

1. **`require_operation_shape`** — the matrix is 6 REPLACE and 1 CREATE, the
   CREATE is `conclusion.py`, and the declared count moves 82 → 83 **by exactly
   that one row**. The header prose, the constants and the rows can no longer
   drift apart.
2. **`require_governed_stores_unreachable`** — publication is confined to the
   library root, and no row can reach the capability runtime, the handoff,
   Fabric, Trust or the authority namespaces. Proved **from the matrix**, not
   from a snapshot: a before/after comparison shows only that nothing *did*
   move; this shows nothing *could*.
3. `conclusion.py` must exist after installation — the CREATE actually landed.

Already present and retained: implementation authority and the privileged
surface are asserted unchanged across `--install` via `AUTHORITY_BEFORE` /
`PRIVILEGED_BEFORE`, and `require_gates_closed` proves each grant still pins its
entrypoint.

## 5. Transaction identity

```
TRANSACTION_ID="gen18-$(date -u +%Y%m%dT%H%M%SZ)-$$"   ->   "gen21-..."
```

The prefix was carried forward with the installer and never renamed, so every
transaction written by Generations 19, 20 and 21 identified itself as
Generation 18's. A comment describing the predecessor journal named
`/root/kyri-gen18-transaction`; it is Generation 20's. Behaviour is unchanged —
only what the evidence calls itself.

## 6. Nothing this checkpoint was forbidden to move, moved

| | |
|---|---|
| Runtime source digests | **identical**, all seven, byte-compared before and after |
| Reviewed runtime-source authority | `0bd3b8ac…7c78`, unchanged |
| Matrix | 7 rows — 6 REPLACE, 1 CREATE |
| Library count | 82 → 83 |
| Publication order | `types, state, capacity, recovery, admin, conclusion, cli` |

The diff is one file: `install-generation-21.sh`, +414 / −107.

## 7. Verification

| Run | Result |
|---|---|
| Generation-21 `--verify-source` | **passed** — 40 ADR-0017 properties, 5 regression groups, 4 carried-forward; 7 objects (6 REPLACE, 1 CREATE) |
| Sabotage suite against the new checks | **9/9 caught** |
| Conclusion suite | **29/29 PASS** |
| Generation-20 installer suite | **84 PASS**, 0 FAIL |
| G5 preflight | **36/36** |
| Every other g5 / generation installer suite | clean |
| `test-static` / `test-developer-experience` | clean |
| ShellCheck (CI-pinned 0.9.0) | clean, rc 0 |
| GitHub CI | **6/6 success** at `bfae114` |
| Quick validator | **BLOCKED at step 44** — the known expired-authority failure |
| Full / clean-clone validators | **BLOCKED** — same cause, upstream of anything this checkpoint touched |

### The blocked validators, reported separately as required

```
FAIL: it refused for another reason: REFUSE: the authority is not currently
supported: admission-window-not-open
```

`CADV-000007` expired at `2026-09-23T06:00:00-05:00`. This is **byte-for-byte
the same failure, at the same step, as at G11-BC-AE**, before any of this
checkpoint's edits existed. It was not weakened, and Fabric was not renewed.

Because the validator halts at step 44, the suites beyond it were run directly
instead — every g5 and generation installer suite, static, developer experience,
and the conclusion suite. All clean. That is the coverage the validator would
have provided past the wall.

## 8. One gap, stated

**There is no Generation-21 installer test suite.** Generation 20 has one
(`test-capability-execution-generation20-installer.sh`, 84 assertions) that
drives its installer against a fixture. Generation 21 has none, so the
verification body rewritten here is proved by the sabotage work recorded in §3
and by `--verify-source` itself, not by a suite the validator runs on every
change.

Writing one was outside this checkpoint's scope, which was the correction
itself. It is recorded here rather than left to be noticed after publication.

## 9. Production

Unchanged. Nothing in this checkpoint touched it.

| | |
|---|---|
| Runtime aggregate | `6757304ec093dd87c7aaeffeb14df729b01d3725210e932a42789c4801c01048` |
| Installed runtime | Generation 20 — `cli.py` still `90979a02…` |
| `conclusion.py` installed | **no** |

## 10. Actions not performed

Generation 21 was not installed. `CINV-000003` was not concluded. No `CINV` was
abandoned, recovered or cleaned. **Fabric was not renewed** and no Fabric record
was altered. No Stage-2 or Stage-3 authority assertion was weakened. No runtime
source object changed. `MAXIMUM_SLOTS` is unchanged at 2. Root Authority was not
mounted. ENG-0006 was not begun.
