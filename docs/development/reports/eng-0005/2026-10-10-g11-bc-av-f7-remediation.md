# G11-BC-AV — F7 remediated: a terminal result is authorised by the journal

**Date:** 2026-10-10
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `eeffa9d`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — F7 reproduced, root-caused, fixed, rehearsed against a byte copy of production, and declared as **Generation 24**. **NOT INSTALLED.** G7 remains `BLOCKED_ON_F7` until the reviewer authorises installation.

---

## A. F7, reproduced exactly

The **installed** released validator, read-only against production:

```
$ cd /usr/lib/kyri/python && python3 -m tools.capability.cli validate \
    --store-root /data/kyri/capability-runtime --expected-uid 1000 --expected-gid 1000
{"findings": ["CINV-000002: result-without-execution-authority",
              "CINV-000003: result-without-execution-authority"],
 "status": "reported"}
EXIT=1
```

The repository copy agrees (`EXIT=1`). `EXIT_DENIED` is `1`, returned by
`command_validate` at `tools/capability/cli.py:1030`:

```python
sound = report.status == STATUS_REPORTED and not report.findings
return EXIT_SUCCESS if sound else EXIT_DENIED
```

**The exact predicate**, at `tools/capability/inspection.py`, inside
`validate_store`'s `OUTCOME_PREPARED` branch:

```python
elif linked and adapter_identity is None and not legacy:
    findings.append(f"{identity}: {FINDING_RESULT_WITHOUT_AUTHORITY}")
```

Production is not mutated: runtime `7dfb34e6…2e99` and Fabric `7e2a4ed0…f376b`
before and after.

---

## B. The writer/validator contract, and the two invocations separately

**Why `adapter_identity` is null.** Not inferred — the released source states it
at the point of cause, in `coordinator.py`:

> "No released caller reaches here — `command_invoke` supplies neither an adapter
> nor a binding, **which is why `adapter_identity` is always null** — so this is
> latent rather than live."

The `CINV` is the immutable *pre-execution* record, written before anything
binds; the supervised path executes afterwards and never back-fills it.

**Where authority is durably recorded instead.** `launch.py`'s module docstring
is normative:

> "**The lifecycle transition is the authority.** `RESERVED -> LAUNCH_AUTHORIZED`
> is committed first and is the only thing that decides whether a launch was
> approved. The launch-authorisation record is a *projection* of that decision,
> and the handoff is *materialisation* of it."

**The evidence table, built per invocation rather than assumed identical:**

| | `CINV-000001` | `CINV-000002` | `CINV-000003` |
|---|---|---|---|
| journal | `reserved → launch_authorized → abandoned` | `reserved → launch_authorized → abandoned` | `reserved → launch_authorized → concluded` |
| launch-authorisation record | present | present | present |
| terminal `CRES` | **none** | `CRES-000001` `provider-error` | `CRES-000002` `completed` |
| `adapter_identity` | null | null | null |
| `schema_version` | 2 | 2 | 2 |
| flagged? | **no** — no result | **yes** | **yes** |

`CINV-000001` is correctly unflagged: the predicate needs `linked`.

**Does the validator read any of it? No.** `validate_store` reads
`store.list_records(INVOCATION_KIND)` and `RESULT_KIND` only, plus a residue
walk of those two directories. It never opens `execution/<CINV>/launch-authorisation`
or `execution/transitions/`. The namespaces are reached through a verified root
descriptor, and the validator is given the record store — which is *why* it only
read records, not an oversight in isolation.

**Root cause.** The validator tested for execution authority using the one
signal the released writer does not produce, and ignored the one it does. Nothing
was ever mis-recorded. A writer/validator mismatch, not a lost authority.

---

## C. The invariant

A terminal `CRES` is sound only when execution authority for its `CINV` is
**provable from durable evidence**, in exactly one of three shapes:

1. **SUPERVISED** — the committed append-only lifecycle journal contains a
   `LAUNCH_AUTHORIZED` transition for that `CINV`. The released model, and the
   authority `launch.py` names.
2. **ADAPTER-BOUND** — the invocation record names the governed execution
   mechanism (`_shape` already checks it against `ADAPTER_IDENTITY`).
   Architecturally permitted; currently latent.
3. **LEGACY** — a different schema version, treated exactly as accepted.

Anything else is unproven, and **unproven fails closed**.

### HISTORY, not current state — the trap this turns on

`all_states()` returns the *current* state, and neither terminal state can
answer the question alone:

- **`CONCLUDED` proves it.** ADR-0017 makes `launch_authorized` the only state
  that reaches concluded.
- **`ABANDONED` does NOT.** `abandonment.py`: *"only reserved and
  launch_authorized are abandonable"*. An invocation abandoned straight from
  `reserved` never had a launch authorised.

Production's two flagged invocations differ **exactly there** — `CINV-000003`
concluded, `CINV-000002` abandoned — so a fix that read the current state and
treated a terminal closure as proof would authorise a result nobody authorised.
Both states are also *off the linear order* by construction, so no positional
read of the enum decides it either.

### A secondary finding: the legacy guard is unreachable

`_shape` reports any invocation whose `schema_version` is not the current one as
`record-malformed` **before** the authority branch is consulted. So no legacy
record ever arrives there and the `not legacy` guard cannot fire. It is **kept
exactly as accepted** rather than removed — removing it is a separate decision
from fixing the authority check — and the suite asserts the fact rather than the
behaviour the branch appears to promise.

---

## D. Negative tests, written RED first

`tests/test-capability-execution-result-authority.sh` — **14 assertions, 0 FAIL**.
Fixtures are **real `CapabilityStore`s** in a temporary directory, and the record
shapes are **production's own** (`CINV-000002` and `CRES-000001` as templates,
read-only), with a portable fallback built from the released field sets. So the
fixture cannot drift from the shape the released writer produces, which is the
subject of the defect — and `CINV-000002`'s actual historical shape is exercised
directly rather than approximated.

| | case | before | after |
|---|---|---|---|
| 1 | production-shaped supervised success, journal proves it | **FAIL** | clean |
| 2 | same shape, **no** journalled authority | fails closed | fails closed |
| 3 | fabricated result for an un-launched invocation | fails | fails |
| 4 | authority for *other* invocations does not transfer | fails | fails |
| 5 | **abandoned with no `launch_authorized`** still fails | fails | fails |
| 6 | adapter-bound authority, no journal | clean | clean |
| 7 | legacy caught by the shape check (guard unreachable) | — | asserted |
| 8a/b | refusal result, and >1 result, still mismatches | mismatch | mismatch |
| 9 | prepared with no result still unreported | clean | clean |
| 10 | adapter bound, no result, still `execution-interrupted` | reported | reported |
| 11 | `ABANDONED`/`CONCLUDED` not positionally after `LAUNCH_AUTHORIZED` | — | pinned |

Two RED iterations were corrective rather than cosmetic: the first fixture was a
hand-made store double that lacked the surface `validate_store`'s residue walk
reads, and the second produced `record-malformed` because invented records do not
carry the released field sets. Both were replaced with the real thing.

---

## E. Architecture decision: **no ADR required**

ADR-0015 (`ABANDONED`), ADR-0017 (`CONCLUDED`, and that `launch_authorized` is
the only state reaching it), the first-adapter design §6, §13 and §16, and
`launch.py`'s normative statement about which artefact is the authority already
define supervised execution authority completely. Nothing about authority is
being decided here.

**`ADR_CHANGE_REQUIRED = NO`**, and no execution authority is broadened: the
validator reads more evidence and accepts nothing it could not already prove.

---

## F. Generation 24 — declared, NOT installed

Derived from repository governance, not assumed: installers exist for
generations 20–23, so the next is **24**.

`provisioning/execution/install-generation-24.sh` — **three REPLACE rows, one
coherence group `E`**, with the matrix derived from actual dependencies:

| order | object | why here |
|---|---|---|
| 1 | `tools/capability/execution/state.py` | **provides** `launch_authorised`; the only new symbol |
| 2 | `tools/capability/inspection.py` | the signature and the predicate that consume it |
| 3 | `tools/capability/cli.py` | the only released caller of both |

`FAIL_CLOSED_FIRST` is the provider and `OPERATOR_SURFACE_LAST` is `cli.py` —
publishing the surface first would call an accessor that does not exist. Unlike
Generation 23, **intermediate publication states exist**, and the order makes
each one a working library: provider-only is the old behaviour with an unused
accessor; provider-plus-predicate is the old behaviour with an argument nothing
passes.

`provisioning/execution/gen24-operator-ceremony.txt` is the operator text.

### The installer's own verification found four defects in itself

`--verify-source` is read-only and I ran it repeatedly; each refusal was a real
inherited-from-gen-23 defect:

1. the REPLACE count was pinned at 1;
2. the coherence group was pinned to `L`, and `E` had no name — a split would
   have reported *"unknown group E"*, the exact diagnostic failure the name table
   exists to prevent;
3. the staging loop still named `CORRECTION_SOURCES`, so the structural proof was
   pointed at a tree without `state.py`;
4. three passages still argued that a single row cannot be half-published.

**Final state: `Generation 24 source verification: all checks passed. 3 object(s)
would change (3 REPLACE, 0 CREATE).`**

---

## G. Rehearsal against a byte copy of production

The copy was proved byte-equal to production first, then:

| | result |
|---|---|
| **the real production state** | **`findings: []`, EXIT 0** |
| remove `CINV-000003`'s `launch_authorized` record | both findings return |
| remove the whole transitions journal | both findings return |
| corrupt a record to name another `CINV` | both findings return |
| **fabricate a `CRES` for an invocation with no journal** | **only `CINV-000099` flagged** |

The last row is the one that proves the fix is **semantic, not suppression**: in
a single run, the two real invocations validate clean while the fabricated one is
caught. The three middle rows are fail-closed: an unvalidatable journal proves
nothing *for anyone*, which is stronger than strictly required and is the right
direction to err.

Production runtime re-measured `7dfb34e6…2e99` after every sabotage.

### And against live production, with the repository fix

```
{"findings": [], "status": "reported"}   EXIT=0
```

---

## H. Eleven sabotages, each a plausible wrong fix

`tests/test-capability-execution-generation24-installer.sh` — **51 PASS / 0
FAIL**. Every sabotage below makes production validate clean, which is exactly
why a digest check and a production-only test cannot distinguish them from the
right fix:

| sabotage | caught by |
|---|---|
| the accessor reduces to the current state | reads the journal through `_scan` |
| a terminal closure is treated as proof | no terminal closure in its executable code |
| the chain is no longer validated | validates with `_resolve` first |
| the predicate gains an unconditional accept | adapter-bound path check |
| **the supervised accept path is removed** | **membership read off the comparison** |
| the finding is suppressed | `validate_store` still reaches it |
| the default stops meaning "nothing proven" | default is `None` |
| `validate_store` loses the argument | keyword-only check |
| `command_validate` stops supplying evidence | surface check |
| the journal read becomes a hard-coded answer | asks `state.launch_authorised` |
| findings stop denying the exit code | still exits `EXIT_DENIED` |

**One sabotage exposed a real weakness in my own verifier.** Removing the
supervised accept path with `if False:` was **NOT CAUGHT**, because the check
only asked whether `authorised` *appeared* — and the parameter name survives in
the signature whatever the body does. The property is that the identity is tested
for **membership** of the journalled set, so it is now read off the `ast.Compare`
rather than off the text. A weaker verifier would have shipped a fix that
rejected production again.

**And my structural proof initially tested prose, not structure.** Two checks
grepped whole function bodies for `ABANDONED`, `CONCLUDED` and
`launch-authorisation`, and failed — because the implementation's own docstrings
*name all three while explaining why none is the authority*. That is the defect
class G7 recorded as **F4**, and this instance was mine. The docstring is now
removed before the properties are asked.

Two sabotages were initially broken, both because a literal `\n` inside a bash
double-quoted string is not a newline: one produced source that no longer parsed,
the other never matched its anchor. The harness reported both as **BROKEN
SABOTAGE** rather than passing them, which is what that guard is for.

---

## I. Registration

| | |
|---|---|
| `tools/dev/run-validation.sh` | both suites registered; totals **measured**, not incremented |
| `.github/workflows/ci.yml` | both suites registered |
| `provisioning/execution/g5-preflight.sh` | Generation 24 declared as pending |

The `g5-preflight` declaration moves each **installed** digest into the baseline
list and appends the Generation-24 digest as a successor — the pattern
`generation_declares` actually requires, which looks for the installed digest
among the *baselines*. A first attempt appended to the successors alone and was
caught by the g5-preflight suite.

The **developer-experience suite caught** that local validation ran two suites CI
omitted — exactly the drift that check exists to refuse.

---

## I-BIS. Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **142/142**, 0 FAIL, 0 skips |
| `run-validation.sh` (full) | **167/167**, 0 FAIL, **0 host-only skips** |
| clean clone of `3813241` | **167/167**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `3813241` | **6/6 green** |

Both new suites run in the clean clone, at steps 100 and 101.

Suite-level, all 0 FAIL: result authority **14**, Generation-24 installer **51**,
`test-capability-runtime` **1089**, lifecycle 45, capacity 31, conclusion 33,
abandonment 26, provenance-correction 22, legacy-compatibility 13,
recovery-discovery 19, supervision 32, mutation 38, Generation-23 installer 56,
g5-preflight 36, developer-experience 141, static 869, no-production-escape 4,
and both real-container E2E suites.

**Fabric, runtime and Trust byte-identical throughout**, measured around every
executable group.

### The installed runtime is deliberately untouched

```
installed inspection.py  adb0e46b…      (the PRE-fix bytes)
installed validator says  2 findings     (F7, still present)
```

Generation 24 is declared and NOT installed, so the finding is still live on the
host. That is the expected state of this checkpoint, and it is why G7 cannot be
re-entered yet.

---

## J. Production state

| store | aggregate | moved? |
|---|---|---|
| `/var/lib/kyri/fabric` | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` | no |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | no |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | no |

No generation installed; no `CINV`, `CRES`, `CADM` or `CMUT` touched; no record
migrated or rewritten; no lifecycle mutation; no capability executed; no Fabric
renewal; no closure ceremony run; the ledger is **not** updated as closed;
nothing merged, tagged or released; ENG-0006 not begun.

---

## K. G7 status

**`G7_STATUS = BLOCKED_ON_F7`.**

The G7 report is **not rewritten**. Its §G decision stands as what I concluded on
2026-10-09, and a new §G-BIS records the reviewer's disposition — F7 BLOCKING,
operator closure NOT AUTHORISED — above it. A report edited to look right
afterwards would be worth less than one that shows the recommendation which was
not accepted.

---

## L. Questions for the reviewer

1. **Installation is the next operator act.** Generation 24 is declared,
   self-verified and rehearsed, but not installed. G7 is re-enterable only after
   it is, because the finding is in the *installed* validator.
2. **The fail-closed breadth.** An unvalidatable journal currently proves nothing
   for *any* invocation, so one corrupt record flags every result-bearing
   invocation. I judged erring that way correct; the alternative — per-`CINV`
   validation so one bad record does not shadow sound ones — is a real design
   choice I did not take unilaterally.
3. **The unreachable legacy guard.** Kept exactly as accepted and asserted as
   unreachable. Removing it is a one-line change I deliberately did not make.
4. **O3's live-matrix evidence expires `2026-10-13T06:25:00-05:00`** — now under
   three days. If installation and the G7 re-entry slip past it, the matrix
   masks again and a live re-run needs the renewal ceremony first.
