# G11-BC-AW — Generation 24's identity, corrected and gated

**Date:** 2026-10-11
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `b33a013`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the blocking publication defect is fixed, every stale generation statement is corrected, and the four identity roles are now gated and sabotaged. **Generation 24 is NOT installed.** The F7 validator source is byte-unchanged.

---

## A. The blocking defect, and a second one underneath it

**What the reviewer found.** The committed installer created:

```bash
TRANSACTION_ID="gen23-$(date -u +%Y%m%dT%H%M%SZ)-$$"
```

A Generation-24 transaction identifying itself as Generation 23's — the same
class of defect Generation 21 corrected for an inherited `gen18-` prefix.

**What I found underneath it, and this one I introduced at G11-BC-AV.** The
predecessor's reviewed authority was carried as:

```bash
GEN22_COMMIT="646b12799a0b5438d1d346f56a9a9a9f9e65299a"      # Generation 22's commit
```

while the check that reads it had been reworded at AV to say:

```
halt "the Generation-23 authority is not an ancestor of the Generation-24 authority"
```

**The message and the value were different generations.** I renamed the prose
and not the thing it described, so the installer claimed to verify Generation
23's authority while verifying Generation 22's. It is now
`PREDECESSOR_COMMIT="736c3716…"` — Generation 23's actual commit — named for its
role so the two cannot drift apart again.

---

## B. The fix: two constants, everything derived

```bash
GENERATION=24
PREDECESSOR_GENERATION=23
```

Derived from them, rather than written out: the transaction root, the transaction
identifier, both baseline evidence paths, both target evidence paths, the
prepared and backup suffixes, the fault-injection variable, and **every
executable diagnostic**.

Measured across the checkpoint: **58 lines naming a generation literally
removed, 81 deriving it added.** Executable diagnostics still naming a generation
literally: **0**.

Four were single-quoted `printf` formats that would have printed the literal
`${GENERATION}` to the operator's console. ShellCheck caught those (SC2016);
they now pass the role as a format argument, so nothing else in the string can
expand by accident either.

### Classified, not substituted

| | occurrence | disposition |
|---|---|---|
| `TRANSACTION_ID="gen23-…"` | transaction identity | **fixed** — derived |
| `GEN22_COMMIT` name + value | predecessor authority | **fixed** — `PREDECESSOR_COMMIT`, Generation 23's commit |
| "the host is at Generation 22" (baseline, ×14) | predecessor state | **fixed** — derived |
| "Generation 23 is already installed" (×2) | target state | **fixed** — derived |
| "host is at Generation 22 and ready for the Generation-23 installation" | both roles in one line | **fixed** — derived |
| "the transaction rolled back: … Generation 22" | rollback | **fixed** — derived |
| "recovery rolled the transaction back … Generation 23 is not installed" | recovery | **fixed** — derived |
| "Generation 23 / supervised execution runtime …" (×3) | success/failure banner | **fixed** — derived |
| "the Generation-22 library evidence is missing" on `TARGET_*` | named the wrong role entirely | **fixed** — target derives, baseline derives |
| `/root/kyri-gen23-{library,helper}-digests.txt` | **predecessor evidence** | **RETAINED** — Generation 23 is the true predecessor |
| `.kyri-gen24.gen23` backup suffix | target over predecessor | **RETAINED**, now derived |
| "already exist at Generation 23", "unlike Generation 23" | true statements about the predecessor | **RETAINED** |
| EXCLUDED list "carried forward from Generation 22" | historical provenance | **RETAINED** |
| "G11-BC-E accepted before Generation 22" | historical fact | **RETAINED** |
| "what refused a COMMITTED Generation-22 transaction" | historical incident | **RETAINED** |

**28** derived predecessor references; **4** historical comments naming
Generation 22 or 15 deliberately kept. The identity gate exempts comments for
exactly that reason — the history genuinely names them.

---

## C. Why `--verify-source` and 51 assertions passed — the real answer

**The suite asserted the defect.** Verbatim, from the committed file:

```bash
if grep -q 'TRANSACTION_ID="gen23-' "${INSTALLER}"; then
  pass "the transaction journal identifies itself as Generation 23's"
```

Inherited from Generation 23's suite — where `gen23-` *was* the correct answer —
and never inverted when I adapted it. So the installer created Generation-23
transaction IDs and the suite reported that as a **pass**, in a message that said
so out loud. Fifty-one assertions agreed with it, and `--verify-source` never
looked at identifiers at all: its structural proof is about the F7 authority
properties, and every generation name in the file is a *string* that nothing tied
to the generation being installed.

**The lesson is not "check for `gen24-` instead".** A literal expectation is
precisely what rots when a file is adapted. So:

- the installer **gates its own identity** in every mode, from the two constants;
- the suite **reads the declared constants** and refuses any identifier that
  hard-codes a generation at all.

There is no literal left for the next generation to inherit.

### The gate: four roles, from the constants

`require_generation_identity`, run before anything else in every mode:

1. **transaction prefix = the generation being installed** — the assignment must
   *derive* from `GENERATION`, and no literal `gen<N>-` prefix may appear;
   `GENERATION == PREDECESSOR_GENERATION + 1`; the filename must match the
   declared generation.
2. **predecessor generation = the evidence baseline** — both baseline paths.
3. **target generation = this installer's own** — both target paths and the
   transaction root.
4. **the diagnostics agree with those roles** — the file is read back, and no
   line carrying `printf`/`halt`/`bad`/`ok`/`note` may name a generation
   literally. Comments exempt.

---

## D. Nine sabotages, one per role

`tests/test-capability-execution-generation24-installer.sh` — **77 PASS / 0
FAIL** (was 51). Every role refuses independently, by its own named reason:

| sabotage | the gate's refusal |
|---|---|
| **the transaction prefix reverts to `gen23-`** — the committed defect | the transaction identifier is not derived from GENERATION |
| the prefix is hard-coded to `gen24-` | the transaction identifier is not derived from GENERATION |
| the baseline evidence names Generation 22 | the baseline library evidence … is not Generation 23's |
| the target evidence names the predecessor | the target library evidence … is not Generation 24's |
| the transaction root names the predecessor | the transaction root … is not Generation 24's |
| `GENERATION=25` with this filename | this file is … but declares GENERATION=25 |
| `PREDECESSOR_GENERATION=22` | a generation installs on its immediate predecessor |
| a success diagnostic names a generation literally | an executable diagnostic names a generation literally |
| a rollback diagnostic names a generation literally | an executable diagnostic names a generation literally |

Note the second row: hard-coding `gen24-` — the *right value* — is refused too.
The property is derivation, not the answer, because the right value written by
hand is what the next adaptation gets wrong.

### Two defects in my own test harness, found by building it

**The first mechanism was vacuous.** It ran the sabotaged installer with
`--verify-source` and required a refusal. All nine cases were "caught" — by
`STOP: the working tree is not clean`, which fires long before the identity gate
and fires whenever the suite runs with uncommitted changes. Nine sabotages passed
while proving nothing, in nine identical lines of output. The gate is now
extracted and run in isolation with its own stubs, so the refusal is the gate's
own and does not depend on the tree. The unsabotaged gate is required to pass
first, so a refusal is attributable.

**And `grep -c` exits 1 on a zero count**, which under `set -Eeuo pipefail`
aborted the assignment silently — which is how the two transaction cases first
refused "without naming a reason". Guarded with `|| true`, so the `halt` reports
the problem.

One more: the predecessor-commit check initially matched *any* mention of
`GEN22_COMMIT` and so refused the installer's own comment explaining the defect.
It now matches an **assignment**.

---

## E. Scope: the F7 validator is byte-unchanged

| object | digest | same as G11-BC-AV? |
|---|---|---|
| `tools/capability/execution/state.py` | `87abff5bdde4ad295f605df2f39bac3a2e028f833dc53e6f2725cd2d457bba53` | **yes** |
| `tools/capability/inspection.py` | `1c2d27d7f003e70ee4fcc4ede004530b0587dfcd65f7180a59caaa03b2d3b99b` | **yes** |
| `tools/capability/cli.py` | `211cf173e780d7031ec78180c9890b046ae0ec70fdcddd9e479eaa3e6fad3095` | **yes** |

No F7 implementation change, and the matrix digests therefore did not move. This
review exposed no separate defect in the validator.

**The operator ceremony was audited and needed no change** — every generation
reference in it is either the true predecessor (`gen23` evidence, "targets
already exist at Generation 23", "unlike Generation 23") or this generation's own
transaction root.

---

## F. Validation

| run | result |
|---|---|
| Generation-24 `--verify-source` | **PASS** — "publishing 24 over 23, transaction gen24-…, and no executable diagnostic names a generation literally"; 3 REPLACE, 0 CREATE |
| Generation-24 installer suite | **77 PASS / 0 FAIL** |
| F7 result-authority suite | **14 PASS / 0 FAIL** |
| g5-preflight suite | **36 PASS / 0 FAIL** |
| Generation-23 installer suite | 56 PASS / 0 FAIL — untouched |
| developer-experience | 141 PASS / 0 FAIL |
| static | 870 PASS / 0 FAIL |
| no-production-escape | 4 PASS / 0 FAIL |

**Fabric, runtime and Trust byte-identical throughout.**

---

## G. Production state

| store | aggregate |
|---|---|
| `/var/lib/kyri/fabric` | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |

**Generation 24 is NOT installed.** No production mutation, no Fabric change, no
capability executed, no runtime record edited, G7 not re-entered, no closure
ceremony run.

---

## H. Questions for the reviewer

1. **The gate exempts comments, deliberately.** The history genuinely names
   Generation 22 and Generation 15, and a check that refused those would refuse
   the explanation of this very defect along with it. The cost is that a *comment*
   can still be wrong. I judged a false refusal worse than a stale comment; it is
   a line somebody could draw elsewhere.
2. **The gate reads its own source**, which is unusual. It is how the fourth
   property is checkable at all — the strings are the thing that drifted — but it
   does mean the installer's self-check depends on its own file being readable at
   the path it was invoked from.
3. **Generation 25 inherits this.** The two constants and the gate travel with the
   file, so the next adaptation starts from a file that refuses to lie about its
   own generation. What it will NOT catch is the matrix digests being stale,
   which is a different property and still rests on `--verify-source`.
4. **O3's live-matrix evidence expires `2026-10-13T06:25:00-05:00`** — about two
   days. Installation, the G7 re-entry and the closure decision all sit behind it.
