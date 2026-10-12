# ENG-0005 G11-BB-L — the Generation-15 preflight refusal, root-caused

**Status: both defects were mine, both are fixed, and production was never
touched.** The host is still Generation 14. No transaction journal, no
publication, no residue. Generation 15 is **not** re-authorized for production
by this report.

Branch `arch/eng-0005-execution-transition`, HEAD `aaf488a`.

---

## 1. Production mutation state — none

The installer refused during preflight and refused again at the gate. Nothing
was written.

```
GEN15_TRANSACTION_JOURNAL   ABSENT
```

Proven from source ordering rather than asserted: in `--install`,
`require_gates_closed` runs at line 1441 and `mkdir -p "${TRANSACTION_ROOT}"` at
line 1444. The refusal was *"the reconcile grant is installed"*, which is that
gate — **three lines before any journal could exist**. `/root` is unreadable to
the coordinator, so the operator should confirm `/root/kyri-gen15-transaction`
is absent, but no code path could have created it.

Verified read-only:

```
five REPLACE targets   all still predecessor bytes
two CREATE targets     both still absent
transaction residue    0 files matching *.kyri-gen15.*
library aggregate      3dd951f569d7f5f050de5154c641ac1327834580a142fb3eb0a9707d842f27fd  = BB-K
libexec aggregate      489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86  unchanged
sudoers aggregate      f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9  unchanged
fabric                 7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96  unchanged
trust                  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f  unchanged
object count           79      helper compatibility  compatible, 0 blocking
CINV-000001            1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV count 1           CRES count 0
```

`PRODUCTION_MUTATION = NONE`. The refusal was clean.

## 2. Root cause 1 — the baseline compared against the wrong predecessor

`require_baseline` does two things, and only one of them knew about ceremonies
that ran after Generation 14.

**The count check was right** (lines 719–725): it adds
`helper_ceremony_library_creates` to the Generation-14 expectation, so 79 = 78
+ 1 passed.

**The digest check was not** (lines 732–751): it compared *every* installed
`.py` against `BASELINE_LIBRARY_EVIDENCE` — the Generation-14 evidence file —
with no overlay at all.

So the same function used the overlay model for counting and ignored it for
comparing. Inherited verbatim from the Generation-13 installer, where it was
correct: at that time no helper ceremony had published into the library root.

### The four paths, classified

They are **exactly** the G11-AX ceremony's library-root rows — the whole
failure, with nothing left over:

| path | governed by | in the Gen-15 matrix? | excluded from Gen-14 comparison? | accepted digest authority |
| --- | --- | --- | --- | --- |
| `kyri_exec_reconcile.py` | G11-AX, **CREATE** | no | yes — it postdates the evidence entirely | AX matrix target `29175d5a…` |
| `kyri_exec_transition_action.py` | G11-AX, REPLACE | no — it is Phase 8's | yes | AX matrix target `7703231318f7…` |
| `kyri_exec_transition.py` | G11-AX, REPLACE | no | yes | AX matrix target `de264c6490e0…` |
| `kyri_exec_verify.py` | G11-AX, REPLACE | no | yes | AX matrix target `f49c29571a4e…` |

`kyri_exec_quota.py` was **not** in the AX matrix, still matches Generation-14
evidence, and correctly did not appear in the failures — which is the check that
the explanation is complete rather than merely plausible.

### The fix

The accepted predecessor is now **Generation 14 plus what accepted ceremonies
published after it**. `helper_ceremony_accepted_digest` reads one path at a time
out of the accepted ceremony's own matrix — the same file the count check
already reads, so the two cannot disagree — and returns the accepted target for
that object.

**This is not "ignore helper files".** An AX-governed object at any other bytes
still refuses. A library-root object no ceremony declares is still judged
against Generation-14 evidence and still refuses. **Historical Generation-14
evidence was not touched.**

`GEN15_PREDECESSOR_OVERLAY_MODEL = PASS`.

### A third defect the fix introduced, and how it showed itself

The overlay lookup returns non-zero for *"no ceremony declares this object"* —
the common case. Under `set -Eeuo pipefail` the assignment
`overlaid="$(lookup …)"` inherits that status and **errexit ended the run
silently**, with no message at all. The fixture caught it immediately because
`--verify` stopped mid-report. The assignment now tolerates it explicitly.

## 3. Root cause 2 — the gates check outlived its premise

`require_gates_closed` required **all three grants absent**. At Generation 13
that was simply a true statement about the host: G3 was closed, nothing had ever
been granted, and "absent" and "not installed by anybody" were the same claim.
G11-BA then installed the launch and reconcile grants, and this check —
inherited unchanged — refused the production host for holding exactly the grants
the accepted deployment plan says it should hold.

**No stronger source reason requires their absence.** I looked for one, because
the ruling asked me to stop if I found it. The Phase-8 matrix settles it: this
generation moves `helpers.py`, the rule that decides whether installed helper
bytes are current, to declare the **corrected** digests while the predecessor
helpers are still installed. The moment it lands, compatibility is
`incompatible` and `supervision_ready` is false. **A grant is permission to ask;
readiness is permission to proceed, and readiness closes.**

### The fix — precise instead of absolute

```
verify grant                 must be ABSENT           (nothing has ever authorised it)
launch / reconcile grants    may be present, and if present must pin the
                             entrypoint bytes THIS HOST carries
any other kyri-* grant       refuses
```

A grant pinning bytes that are not installed is a grant nobody reviewed, so it
refuses too.

`GEN15_EXISTING_GRANTS_ALLOWED = PASS`. `VERIFY_GRANT_ABSENT_REQUIRED = YES`.

### One residual worth stating

The old check removed a race by construction: with no grants, nothing could
invoke *during* a transaction, so a partially-published runtime could not be
executed against. With grants present that window is theoretically open between
publishing an early coherence group and publishing `helpers.py`.

It requires a second operator deliberately running `invoke` →
`authorise-launch` → `execute` while a root ceremony is mid-transaction. The
platform has no autonomous execution path, `CINV-000001` is unresolved and not
resumable, `CINV-000002` is unspent, and no container exists. I judged that
acceptable rather than silently ignoring it, and I am recording it rather than
deciding it: if the reviewer wants it closed, the answer is to publish group H
first so readiness shuts before anything else moves, not to remove the grants.

## 4. Root cause 3 — the operator block could reach `--install` after a refusal

`GEN15_OPERATOR_FAILFAST_DEFECT = CONFIRMED`, and it is mine. The BB-K block
listed `--verify` and `--install` as separate commands with no `set -e` and no
chaining, so `--install` ran after `--verify` had already refused. It refused
safely — but safety came from the installer, not from the ceremony, and a block
that relies on the next gate catching what the last one missed is not a
ceremony.

Corrected form, used in §6:

```bash
set -Eeuo pipefail
```

plus explicit `&&` chaining, so `--install` is unreachable unless every
preceding gate returned zero.

## 5. The fixture now reproduces production

The Generation-15 fixture was Generation 14 alone. It is now the **actual
accepted production shape**:

```
Generation 14 evidence, written BEFORE the overlays -- it records Gen 14, and
                        everything after it postdates it deliberately
+ G11-AX library-root publications   three REPLACE and one CREATE, from the AX matrix
+ G11-AW deployment identities
+ G11-BA launch and reconcile grants, each pinning the installed entrypoint
+ the verify grant still absent
```

Both production failures reproduced against it RED-first, then went green.

**Six negative controls hold the boundary that was not weakened:**

```
ok  an AX-governed object at undeclared bytes is still refused
ok  an ungoverned extra library-root object is refused
ok  the verification grant is still refused
ok  a grant pinning bytes the host does not carry is refused
ok  an undeclared Kyri grant is refused
ok  a pinned entrypoint whose bytes moved is refused
```

### Results against the production shape

```
GEN15_VERIFY_PRODUCTION_SHAPE_FIXTURE   PASS   and still non-mutating
GEN15_FIXTURE_INSTALL                   PASS   79 -> 81 objects
GEN15_FIXTURE_VERIFY_INSTALLED          PASS
```

`--verify` reports: *"2 accepted execution grant(s) present, each pinning the
installed entrypoint; the verification grant is absent"* and *"the host is at
Generation 14 and ready for the Generation-15 installation: 5 REPLACE, 2 CREATE,
7 changed objects across 3 coherence groups, object count 78 → 80"*.

Post-install, unchanged from BB-K's prediction: helper compatibility
**incompatible**, three stale, `supervision_ready` false, both grants unchanged,
verify grant absent, `/usr/libexec` byte-identical.

43 assertions in the suite, all passing, including recovery at all ten
publication boundaries.

## 6. The corrected operator block — for the next authorization, not for now

Presented so the correction is reviewable. **This report does not re-authorize
the installation**; that needs a fresh authorization checkpoint.

```bash
set -Eeuo pipefail
cd /opt/schott-platform

sudo test -f /root/kyri-gen14-library-digests.txt
sudo test -f /root/kyri-gen14-helper-digests.txt
sudo test ! -e /root/kyri-gen15-transaction

sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --install
```

Under `set -Eeuo pipefail` and `&&`, `--install` is unreachable unless every
preceding gate returned zero.

## 7. Validation

```
Gen-15 focused suite   PASS   43 assertions
LOCAL_QUICK            PASS   108/108
LOCAL_FULL             PASS   133/133
GITHUB_CI              PASS   6/6 at aaf488a
CLEAN_CLONE_VERIFY     PASS   full clone of the pushed commit, suite green
working tree           clean; HEAD == pushed branch head
```

## 8. What this cost, and what it bought

Two defects reached a production console because I ported an installer and
carried two of its assumptions past the point where they were true — and the
preparation fixture was built from Generation 14 alone, so it could not have
caught either. The fixture is now the real shape, which is why both failures
reproduce there and why the next attempt is testable before it is attempted.

The refusals themselves worked exactly as designed: fail-closed, before any
journal, with nothing published.

## 9. Next

A fresh authorization checkpoint against the corrected installer. Still
prohibited until then and until separately authorized: installing Generation 15,
installing helpers, modifying sudoers, renewing Fabric, touching `CINV-000001`,
spending `CINV-000002`.

```
HOST_GENERATION 14   HELPER_INSTALL_AUTHORISED NO   PRODUCTION_INVOKE_AUTHORISED NO
```
