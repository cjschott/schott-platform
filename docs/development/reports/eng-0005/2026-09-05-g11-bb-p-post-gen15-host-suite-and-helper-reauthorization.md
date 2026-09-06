# ENG-0005 G11-BB-P — the host suites made successor-aware, and the helper ceremony re-derived

**Status: all six host-coupled suite failures fixed and mutation-tested. The
helper ceremony is proven again against a Generation-15 host.** Production was
not mutated: no privileged command was run and none succeeded. Generation 15
stays installed and accepted, the predecessor helpers stay installed, execution
stays fail-closed.

```
HOST_GENERATION              15        GEN15_ACCEPTED  YES
HOST_COUPLED_FAILURES_BEFORE 6
HOST_COUPLED_FAILURES_AFTER  0
HOST_SUITE_SUCCESSOR_AWARE   YES
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. The six, classified before anything was changed

All 29 host-only suites were run individually against the accepted
Generation-15 host. Six failed, and the classification below was completed
before a line was edited.

| suite | failing assertion | host state it reads | implicit assumption | successor-aware model |
| --- | --- | --- | --- | --- |
| `bb-helper-ceremony` | `B: Gen-15 with old helpers reports compatible`; `E: the complete target reports incompatible` | live `tools/**` path set | the live path set is Generation 14's | subtract Generation 15's CREATE rows before reconstructing |
| `generation12-packaging` | `the derived Generation-12 surface is 70 objects (got 72)` | live library, `rglob('*.py')` | successors are Gen 13 + G11-AX | read **every** later ceremony's CREATEs |
| `generation13-packaging` | `the live host is wholly at one of the two declared generations`; `the declared counts are the matrix's own` | live library digests and count | the only successor is Gen 14 | read the successor **chain**; offset by every later library CREATE |
| `generation13-installer` | `--verify did not accept a Generation-12 host: the installed library holds 73 objects, expected 70 + 1` | `cp` of the live library | rewinding Gen 13's own rows is enough | also remove later generations' CREATEs |
| `generation14-installer` | `the installed library holds 81 objects, expected the Generation-13 78 + 1` | `cp` of the live library | rewinding its own single row is enough | rewind Generation 15 to the Gen-13 authority |
| `helper-ceremony` (G11-AX) | `the pre-ceremony fixture could not be built` | `cp` of the live library, then a `helpers.py` digest gate | the live `helpers.py` is Generation 14's | rewind Generation 15 to the Gen-14 authority |

## 2. Shared root cause — one idea, three spellings, none of which knew about 15

They are **not** three unrelated bugs. Every one reconstructs a predecessor
from the live host, and every one hard-codes which successors exist. Three
different spellings had grown up:

```
A  path set from the live host, bytes from git        bb-helper-ceremony, generation15-installer
B  cp -a the live library, then undo some rows        generation13-installer, generation14-installer,
                                                      helper-ceremony
C  derive from the live tree, subtract successors     generation12-packaging, generation13-packaging
```

Spelling C was already successor-aware and still failed, because its successor
list named the *immediate* next ceremony rather than the chain — `generation12-packaging`
listed Generation 13, and `generation13-packaging` listed Generation 14. Each
was correct exactly until one more generation landed. `generation12-packaging`'s
own docstring had predicted this in writing: *"on Generation 13 this fails saying
so."* It did. Then Generation 15 did it again, to six suites at once.

**This is the same shape as the defect BB-O fixed in the installer**: one idea
written in several places, corrected in some of them. So the idea is now written
once.

### 2.1 The specific patterns, checked

Against the list this checkpoint was asked to look for:

```
copying live /usr/lib/kyri/python                             YES  three suites (spelling B)
assuming installed runtime == Gen14 baseline                  YES  helper-ceremony's RUNTIME_HELPERS_SHA gate
deriving baseline from live object count                      YES  both packaging suites
comparing live bytes to historical generation evidence        YES  and correct -- left alone
using the installed helpers.py for BOTH sides of a matrix     NO   bb-helper-ceremony uses each
                                                                   fixture's own rule, correctly
assuming handoff/runtime directories are empty                NO   no suite asserted this
```

The one that is **not** a defect is worth stating: comparing live bytes to
historical evidence is what these suites are *for*. Nothing here was changed to
accept whatever production currently holds, and no expected digest was bumped to
match the host.

## 3. The fix — `tests/lib/succession.sh`

One primitive, sourced by the suites that need it:

```
succession_library_rows <ceremony>        the library-root rows of a matrix
succession_created_by   <ceremony>...     every library-root pathname they CREATE
succession_rewind <lib> <repo> <commit> <ceremony>...
                                          CREATE  -> remove the pathname
                                          REPLACE -> restore from <commit> via the
                                                     row's declared SOURCE path
```

**Why the successor list is passed in rather than derived.** "Later" is not the
question these suites ask. A suite reconstructing Generation 13 must rewind
Generations 14 and 15 but **not** the G11-AX helper ceremony, whose library-root
publication its counts already include. Only the suite knows what its own
expectations already carry, so each names its successors explicitly and the list
is reviewable at the call site.

**Why it cannot become "accept whatever is installed".** A rewind is driven by
governed matrix data and restores bytes from a **named historical commit**. An
object no listed ceremony declares is left exactly as the live host holds it, so
drift in it still reaches the assertions that refuse it. And a REPLACE row whose
source the commit does not carry makes the rewind **fail**, rather than quietly
leaving the successor's object in place — which is precisely the failure mode
this checkpoint exists to end.

`generation15-installer` was migrated onto the primitive as well, so its
private copy of the same subtraction is gone and there is one spelling in the
tree.

## 4. RED-first, and mutation-tested

Every fix was proved to be load-bearing by breaking it and watching the failure
return.

**RED first.** The classification in §1 *is* the RED evidence: each failure was
captured from the accepted Generation-15 host before any edit. The decisive one,
for the suite that matters most:

```
STOP: the installed readiness rule is 74b84015… , not the Generation-15
6dd93606… : install Generation 15 before this ceremony
```

`run_gen15 --install` was failing inside the fixture and its failure was
swallowed by `|| true`, so the fixture stayed at Generation 14 and **every**
compatibility case silently judged the wrong runtime. That is why B and E came
out inverted rather than merely wrong.

**Mutation.** With `succession_rewind` stubbed to a no-op and
`succession_created_by` to empty:

```
bb-helper-ceremony       FAIL      generation14-installer  FAIL
generation13-installer   FAIL      helper-ceremony         FAIL
generation15-installer   FAIL
```

And with each Python successor list reverted to its immediate-successor form:

```
generation12-packaging   FAIL      generation13-packaging  FAIL
```

All six restore their original failure. No fix is incidental.

**The primitive has its own suite** — `tests/test-succession-lib.sh`, portable,
registered in local validation and in CI:

```
PASS  created_by returns the library-root CREATE rows only
PASS  library_rows skips the /usr/libexec row, which was never library surface
PASS  a ceremony that does not exist contributes nothing
PASS  rewind restores a REPLACE row to the named commit's bytes
PASS  rewind removes a CREATE row's pathname
PASS  a restored object carries the mode a real host carries
PASS  an object no ceremony declares is left exactly as found, so drift still surfaces
PASS  a REPLACE row whose source the commit does not carry is refused
PASS  the unsatisfiable rewind left the object alone rather than half-restoring it
PASS  an operation the rewind cannot undo is refused rather than skipped
PASS  a rewind leaves the repository untouched -- historical evidence is read, never rewritten
```

Those last five are the "bogus later generation" and "historical evidence is
immutable" boundaries, asserted rather than argued.

## 5. The helper ceremony, re-proven against a Generation-15 host

The primary gate. **31 assertions, 0 failures**, and the matrix is now the right
way up:

```
A  Gen 14 + predecessor helpers            compatible     (current production before Gen 15)
B  Gen 15 + predecessor helpers            incompatible   <- was compatible
C  Gen 14 + successor helpers              incompatible
D  Gen 15 + partial successor subsets      000 001 010 011 100 101 110  all refuse
E  Gen 15 + complete successor helpers     compatible     <- was incompatible
```

```
PARTIAL_DEPLOYMENT_REFUSAL   PASS     all 2^3 subsets
REQUIRED_PRODUCTION_ORDER    GEN15_THEN_HELPERS
WORKER_ANCHOR_FIX            PASS
QUOTA_ANCHOR_FIX             PASS
```

## 6. The helper delta, re-derived from the current host

Not carried from BB-J: re-derived from the **installed Generation-15
`HELPER_SOURCES` declaration** against reviewed source at `ef4f744`, one path at
a time.

```
declared helpers 8      HELPER_SOURCES rows 8

REPLACE  /usr/libexec/kyri-exec-worker.py
         6d06695f43357007 -> 2d320630aca559c7   provisioning/execution/kyri-exec-worker.py
REPLACE  /usr/lib/kyri/python/kyri_exec_transition_action.py
         7703231318f7a872 -> b11a2f19bc469ae4   provisioning/execution/kyri-exec-transition-action.py
REPLACE  /usr/lib/kyri/python/kyri_exec_quota.py
         4886d5b323c9dfdf -> 54a9b15c6c6e3b78   provisioning/execution/kyri-exec-quota.py

HELPER_TARGETS 3   HELPER_REPLACE 3   HELPER_CREATE 0   HELPER_REMOVE 0   CARRYOVER 5
```

It matches BB-J's derivation and matches the three objects the installed
readiness rule names as blocking. Three independent routes to the same three
objects.

**Sudoers pins.** Both pinned entrypoints are byte-identical to what the accepted
grants name, and neither is in the delta:

```
/usr/libexec/kyri-exec-transition   0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
/usr/libexec/kyri-exec-reconcile    2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77

SUDOERS_CHANGE_REQUIRED  NO
```

## 7. Production, read-only

Measured directly in this session, without privilege. Nothing was written.

```
flat library            81
helpers.py              6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07   Generation 15
seven Gen-15 targets    all at their accepted target digests
helper compatibility    incompatible, 8 declared, 3 blocking
  stale  /usr/libexec/kyri-exec-worker.py
  stale  /usr/lib/kyri/python/kyri_exec_transition_action.py
  stale  /usr/lib/kyri/python/kyri_exec_quota.py
supervision_ready       false
sudoers aggregate       f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9   unchanged
verify grant            ABSENT
CINV count 1            CRES count 0        CINV-000002 unspent
CINV-000001             1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   UNRESOLVED
fabric                  7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
trust                   53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   unchanged
```

This is exactly the required Generation-15-before-helpers intermediate state.

`PRODUCTION_MUTATION = NONE`.

## 8. Validation

**Host-only suites are reported separately, because CI cannot exercise them.**
`tests/host-only.manifest` says so in terms: *"The local validator is the
authority for everything listed here, and GitHub CI proves none of it."* A green
CI is therefore **not** evidence for anything in §1–§5.

```
HOST-ONLY SUITES, run individually on the accepted Generation-15 host
  before   20 PASS   3 SKIP   6 FAIL
  after    26 PASS   3 SKIP   0 FAIL
```

The three skips are identical before and after — `g61-verification`,
`profile-transport` and `transition-action` all report *"runs as uid 1000, not
the coordinator identity"*. Pre-existing, unrelated to this change, and
unchanged by it.

```
succession primitive suite   PASS   12 assertions
bb-helper-ceremony           PASS   31 assertions, 0 failures
generation15-installer       PASS   103 assertions, 0 failures
shellcheck                   clean
LOCAL_QUICK                  PASS   109/109
LOCAL_FULL                   PASS   134/134
```

**Clean-clone verification, and its exact reach.** Cloned from `origin`, not
from this working copy:

```
test-succession-lib.sh       PASS   12 assertions    portable
bb-helper-ceremony           PASS   31 assertions
generation15-installer       PASS   103 assertions
generation12-packaging       PASS   53 assertions

generation13-packaging       SKIP   pinned-checkout guard
generation13-installer       SKIP   pinned-checkout guard
generation14-installer       SKIP   pinned-checkout guard
helper-ceremony              SKIP   pinned-checkout guard
```

Four of the seven declare `host_only_requires_pinned_checkout` and so cannot run
from a clone at all — they drive ceremonies pinned to `/opt/schott-platform`.
Their only proof is the local host-only run above, and a clean clone is **not**
evidence for them. Stating that is the point of separating the two.

One thing the validator caught that this checkpoint had got wrong: adding a
suite without updating the declared step count. The run refused —

```
FAILED: step count mismatch — declared 108, executed 109.
Every check ran, but the declared total is wrong. Fix TOTAL_STEPS.
```

— which is the guard working. Both totals were corrected (quick 108 → 109, full
133 → 134) rather than the new suite being left unregistered.

## 9. The helper ceremony is authorized — and not run here

Every condition this checkpoint was told to gate on is met:

| condition | state |
| --- | --- |
| all local host validation green | 26 PASS / 3 SKIP / **0 FAIL**; quick 109/109; full 134/134 |
| helper matrix correct | A compatible, B/C/D incompatible, E compatible; all 2³ partials refuse |
| production exactly Gen 15 + predecessor helpers | 81 objects, Gen-15 declaration, 3 stale helpers |
| sudoers pins still match | both entrypoints byte-identical, neither in the delta |
| verify grant absent | absent, and the ceremony refuses if it appears |
| no unknown bytes | `--verify-installed` PASS at BB-O; no object outside a declared state |

```
HELPER_INSTALL_AUTHORISED = YES        (for an operator, after reviewer acceptance)
```

**This report installs nothing.** It authorizes the operator to run the ceremony
below once this checkpoint is accepted.

### 9.1 The ceremony is a governed artefact, not a fenced block

`provisioning/execution/helper-operator-ceremony.txt`, held to the standard BB-M
set after an unchained block reached `--install` following a refusal. The suite
**executes it against a stub installer** that records every invocation:

```
PASS  ceremony: the operator block sets -Eeuo pipefail
PASS  ceremony: the journal check precedes every installer invocation
PASS  ceremony: with every stage passing, the ceremony completes
PASS  ceremony: the stages run in the declared order
PASS  ceremony: --verify refused -> --install invocation count is 0
PASS  ceremony: --verify refused -> --verify-installed invocation count is 0
PASS  ceremony: --verify-source refused -> --verify and --install counts are both 0
PASS  ceremony: an unexpected helper transaction stops it before any installer runs
PASS  ceremony: the unexpected transaction is left untouched
PASS  ceremony: absent Generation-15 evidence stops it before any installer runs
PASS  ceremony: a present verification grant stops it before any installer runs
```

The suite is now **42 assertions, 0 failures**.

### 9.2 The ceremony, extracted verbatim

Reproduced byte-for-byte from the committed artefact. Paste it as one block; the
`set -Eeuo pipefail` and `&&` chaining are the fix.

```bash
#!/usr/bin/env bash
# The corrected privileged-helper ceremony, exactly as it is to be typed.
#
# This file is reference text, not a script to run: the operator pastes it into
# a root-capable shell so every command and every refusal is visible on the
# console. It lives here rather than only in a report so the test suite can
# execute it against a stub installer and prove the control flow, instead of
# trusting that a fenced block in prose does what its prose says -- which is the
# defect that let the Generation-15 block reach --install after a refusal.
#
# The property under test: no later stage can run after an earlier one refused.
#
# ORDER. This ceremony is second. It must run only against an installed and
# accepted Generation 15: the installer refuses otherwise, because Generation
# 15 carries the readiness rule that declares these corrected helper digests.
set -Eeuo pipefail
cd /opt/schott-platform

# An unexpected transaction is the one condition that must stop everything
# before any installer runs. It would mean a previous ceremony did not finish,
# and the correct response is inspection, not cleanup.
sudo test ! -e /root/kyri-g11-bb-helper-transaction/journal \
  || { printf 'STOP: a helper transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-g11-bb-helper-transaction \
  || { printf 'STOP: helper transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

# The runtime this ceremony is judged by. Generation 15 must already be
# installed and accepted; the installer checks it too, and refuses.
sudo test -e /root/kyri-gen15-library-digests.txt \
  || { printf 'STOP: Generation-15 evidence is absent. Install and accept Generation 15 first.\n' >&2; exit 1; }

# The verification entrypoint stays unauthorised through this ceremony.
sudo test ! -e /etc/sudoers.d/kyri-exec-verify \
  || { printf 'STOP: the verification grant exists. Nothing authorised it.\n' >&2; exit 1; }

sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify-installed
```

### 9.3 Expected result, stated before execution

```
helper compatibility     compatible, 8 declared, 0 blocking
supervision_ready        true          <- first time; the runtime and helper surfaces agree
/usr/libexec entrypoints kyri-exec-transition and kyri-exec-reconcile UNCHANGED
sudoers                  UNCHANGED, verify grant still ABSENT
runtime                  UNCHANGED at Generation 15, 81 objects
CINV-000001              unchanged, UNRESOLVED     CRES 0     CINV-000002 unspent
```

**If `supervision_ready` is not true after a successful ceremony — STOP.** And if
anything under `/usr/lib/kyri/python` other than the two helper library modules
moved, STOP: this ceremony touches three objects and nothing else.

### 9.4 Still prohibited

Renewing Fabric, invoking, authorising a launch, executing, modifying sudoers,
re-running or recovering the Generation-15 install, touching `CINV-000001`,
spending `CINV-000002`. A fresh Fabric chain (`CADV` → `CINST` → `CROUTE` →
`CSEL`) comes after the helper ceremony is accepted, not before.

```
PRODUCTION_INVOKE_AUTHORISED      NO
CINV_000001_FINAL_CLASSIFICATION  UNRESOLVED
CINV_000001_RESUME_AUTHORISED     NO
```
