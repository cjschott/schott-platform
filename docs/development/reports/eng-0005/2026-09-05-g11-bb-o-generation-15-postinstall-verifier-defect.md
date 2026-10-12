# ENG-0005 G11-BB-O — the post-install verifier, root-caused and fixed

**Status: Generation 15 is installed and its bytes are correct. The verifier
that refused it was wrong, and is fixed.** The transaction is `COMMITTED`, the
publication is complete, and production is in exactly the required
Generation-15-before-helpers intermediate state. Nothing was rolled back,
recovered, re-installed, or hand-edited.

```
GEN15_TRANSACTION           COMMITTED
GEN15_PUBLICATION           COMPLETE
GEN15_RUNTIME_TARGET_BYTES  PASS
GEN15_POSTINSTALL_VERIFIER  DEFECTIVE -> FIXED
GEN15_ACCEPTANCE            PENDING_VERIFIER_FIX
```

Branch `arch/eng-0005-execution-transition`, fix commit `51e1c21`.

---

## 1. The host is not rollback-required, and this is why

The four refusals name library-root objects that are **not** Generation-15
targets and were **not** touched by the transaction. Every declared target is at
its declared digest; the journal reached `COMMITTED`; both evidence files were
written; the artefacts were cleaned up. The transaction did what it said.

Measured read-only on the host, without privilege:

```
flat library                81
helpers.py                  6dd936064f1c…  the Generation-15 declaration
result_content.py           present        contract_outcome.py  present
kyri_exec_quota.py          4886d5b323c9…  Generation-14 bytes, correctly NOT reported
```

The four objects the verifier complained about are at the digests the **accepted
G11-AX ceremony** published:

```
kyri_exec_reconcile.py          29175d5a…   AX CREATE    MATCHES accepted target
kyri_exec_transition_action.py  77032313…   AX REPLACE   MATCHES accepted target
kyri_exec_transition.py         de264c64…   AX REPLACE   MATCHES accepted target
kyri_exec_verify.py             f49c2957…   AX REPLACE   MATCHES accepted target
```

So the host holds exactly the bytes an accepted ceremony was accepted for. A
recovery run against a `COMMITTED` transaction would be a rollback of a correct
publication on the strength of a defective check. **Recovery is not indicated
and was not run.**

## 2. Root cause — the same comparison, written twice, corrected once

`--verify` and `--verify-installed` reach different functions, and only one of
them learned what BB-L established.

Line numbers are the pre-fix installer at `6734976`; the post-fix positions are
`require_baseline():796` and `verify_unchanged_surface():1501`.

```
--verify           require_baseline           :749   OVERLAY-AWARE  (BB-L fixed this one)
--verify-installed verify_unchanged_surface   :1458  OVERLAY-BLIND
--install, post-COMMIT
                   verify_unchanged_surface   :1458  OVERLAY-BLIND
```

Both `--install`'s final verification and `--verify-installed` call the same
defective function, which is why the transaction committed and then refused
itself with the identical four lines the operator saw again on re-run.

The pre-install check consulted `helper_ceremony_accepted_digest` before falling
back to Generation-14 evidence. The post-install check did not: it read
`BASELINE_LIBRARY_EVIDENCE` directly for every non-target object, so the
accepted predecessor it compared against was

```
Generation-15 targets  +  PURE Generation-14 carryover
```

instead of

```
Generation-15 targets  +  accepted Generation-14 carryover
                       +  accepted G11-AX overlay for separately governed objects
```

That is precisely the defect BB-L root-caused for `--verify`. BB-L fixed one of
the two readers. **The duplication is the root cause; those four pathnames are
only where it surfaced.**

The two message forms match the production console exactly, and their source
lines are the two branches of that one loop:

| production message | source |
| --- | --- |
| `installed object kyri_exec_reconcile.py is not accounted for by the Generation-14 evidence` | the empty-`recorded` branch — AX **CREATE**, absent from Generation-14 evidence entirely |
| `<path> changed relative to Generation-14 evidence` ×3 | the digest-mismatch branch — AX **REPLACE**, legitimately different |

`GEN15_VERIFY_INSTALLED_ROOT_CAUSE = verify_unchanged_surface compared every
carried-over object against Generation-14 evidence alone, with no accepted-ceremony
overlay, while require_baseline applied one.`

## 3. The four objects, classified

Nothing here is folded into the Generation-15 matrix, and no historical evidence
was rewritten.

| object | governing ceremony | accepted digest | Gen-15 matrix target? | separately governed overlay? | verify-installed must compare against |
| --- | --- | --- | --- | --- | --- |
| `kyri_exec_reconcile.py` | G11-AX, **CREATE** | `29175d5a…4275a46` | no | **yes** | the AX matrix target |
| `kyri_exec_transition_action.py` | G11-AX, REPLACE | `77032313…af1d296a` | no — it is Phase 8's | **yes** | the AX matrix target |
| `kyri_exec_transition.py` | G11-AX, REPLACE | `de264c64…1440f5a6` | no | **yes** | the AX matrix target |
| `kyri_exec_verify.py` | G11-AX, REPLACE | `f49c2957…e33be51f` | no | **yes** | the AX matrix target |

**The completeness check.** `kyri_exec_quota.py` is not an AX row, still carries
Generation-14 bytes, and was correctly **not** reported — by the verifier or by
the fix. An explanation that also predicted a fifth failure would be the wrong
explanation.

`GEN15_POSTINSTALL_OVERLAY_MODEL = PASS`.

## 4. The fix — one reader, not two

Both call sites now resolve through `accepted_library_digest`, which returns the
accepted digest **and the authority that recorded it**:

```
accepted_library_digest <relative>
  -> "ceremony <digest>"   an accepted post-Generation-14 ceremony governs it
  -> "evidence <digest>"   Generation-14 evidence records it
  -> returns 1             NO accepted authority records it  => REFUSE
```

The per-path lookup and the completeness check both read one enumerator,
`helper_ceremony_library_rows`, which reads the accepted ceremony's own matrix.
The overlay is therefore data, not a list restated in the verifier — and a
second accepted ceremony is a one-line data change.

**This is not "ignore helper files".** An overlay object at any other bytes
refuses. A library-root object no ceremony declares is still judged against
Generation-14 evidence and still refuses.

### 4.1 A real gap the fix also closes

`overlay_complete` refuses when an object an accepted ceremony published has
disappeared. The object count could not catch that, because the count
expectation is itself derived from how many overlay objects are *present*
(`helper_ceremony_library_creates` counts installed files), so a deletion moved
both sides of the comparison together. Proven by mutation:

```
overlay_complete disabled -> deleting kyri_exec_reconcile.py is ACCEPTED   <- the gap
overlay_complete enabled  -> "the accepted helper ceremony published
                              kyri_exec_reconcile.py, which is not installed"
```

### 4.2 The sweep

Every reader of `BASELINE_LIBRARY_EVIDENCE` was re-checked. Both comparison
sites now go through the one resolver; the remaining references are existence
checks and the two reverse "evidence records X, which is not installed" loops,
which need no overlay because an AX REPLACE path is in Generation-14 evidence
and an AX CREATE path is covered by `overlay_complete`.

```
OVERLAY_BLIND_READERS_REMAINING = 0
```

## 5. The fixture never reproduced production — two defects

The suite passed `--verify-installed` at BB-M while production refused it. Both
reasons were in the fixture, and both are fixed.

**Defect A — the fixture's "Generation-14 evidence" recorded G11-AX's bytes.**
It hashed its own built tree to produce that file. But the repository at
`946be55` **already carries AX's corrected sources**, so the four AX objects were
materialised at their AX *post* bytes and then recorded as though they were
Generation 14. The overlay applied afterwards was a no-op, and the four objects
that broke production were invisible.

Evidence is now written from the AX matrix's **PRE** column, with its CREATE row
omitted entirely — which is what Generation-14 evidence actually contains: the
bytes that were there before AX ran, and no row at all for a pathname AX had not
yet created.

**Defect B — the fixture followed the host.** Its path set comes from the live
runtime. Once production moved to Generation 15, the fixture picked up
`result_content.py` and `contract_outcome.py` and reconstructed **81** objects
where it declares 79. A suite whose baseline follows the host cannot hold the
host to a baseline. The Generation-15 CREATE rows are now subtracted, read from
the installer's own matrix.

### 5.1 RED-first

With the fixture corrected and the installer untouched, the fixture reproduces
the production console exactly — same four objects, same two message forms, in
both the post-COMMIT verification and `--verify-installed`:

```
FAIL  installed object kyri_exec_reconcile.py is not accounted for by the Generation-14 evidence
FAIL  kyri_exec_transition_action.py changed: 77032313… but Generation-14 evidence records bd32af5d…
FAIL  kyri_exec_transition.py         changed: de264c64… but Generation-14 evidence records 6488044b…
FAIL  kyri_exec_verify.py             changed: f49c2957… but Generation-14 evidence records 3d70707d…
```

Reverting the overlay model reproduces those four and nothing else — which is
the mutation test that the fix is load-bearing rather than incidental.

## 6. Post-fix verdict, and the negative controls

Section E5 runs eighteen assertions against an **INSTALLED** Generation 15,
because that is the surface that was wrong. All pass:

```
PASS  --verify-installed accepts the committed production shape
PASS  the flat library holds 81 objects
PASS  the accepted overlay objects kyri_exec_verify / transition / transition_action / reconcile are exact
PASS  helper compatibility is incompatible with 3 blocking, so supervision_ready is false
PASS  the verify grant is absent and both execution grants remain
```

**The boundaries that were not weakened to reach that verdict**, each requiring
`--verify-installed` to refuse:

```
PASS  an unknown byte in a Generation-15 target is refused
PASS  an unknown byte in an accepted overlay object is refused
PASS  an unknown byte in a carried-over object is refused
PASS  an ungoverned extra library-root object is refused
PASS  a missing accepted overlay object is refused
PASS  the verification grant present is refused
PASS  a grant pinning bytes the host does not carry is refused
PASS  a pinned entrypoint whose bytes moved is refused
PASS  a transaction journal that is not COMMITTED is refused
```

**The control that makes those nine mean something.** An unmutated copy of the
installed fixture must still verify:

```
PASS  post-install control: an unmutated copy of the installed fixture still verifies
```

That control exists because the first draft of this section relaxed modes across
the whole tree before mutating, and the installed set is verified for **mode** as
well as bytes. All nine refused on mode drift and none of them tested what it
named. Each mutator now restores the mode it relaxed.

```
GEN15_FIXTURE_VERIFY_INSTALLED = PASS
GEN15_UNKNOWN_BYTES            = PASS
```

## 7. Validation

```
Gen-15 focused suite   PASS   103 assertions, 0 failures   (85 -> 103)
shellcheck             clean
GITHUB_CI              PASS   6/6 at 51e1c21
CLEAN_CLONE_VERIFY     PASS   clone of the pushed commit FROM THE REMOTE, 103/103
working tree           clean; HEAD == pushed branch head
```

### 7.1 LOCAL_FULL does not pass, and not because of this change

`tools/dev/run-validation.sh` stops at step 15, `Generation-12 packaging`. **The
cause is the Generation-15 installation itself, not this fix** — proven by
stashing this change and re-running, which fails identically:

```
FAIL: the Generation-11 surface is 57 objects (got 59)
FAIL: the derived Generation-12 surface is 70 objects (got 72)
FAIL: every packaged module is either reachable or a declared support module
      (['tools/capability/execution/contract_outcome.py',
        'tools/capability/execution/result_content.py'])
```

The two extra objects are Generation 15's CREATE targets. Because
`run-validation.sh` stops at the first failure, step 15 hides everything behind
it, so all 117 suites were run individually. **Six** host-only suites
reconstruct a baseline from the live runtime and have not been told Generation
15 exists:

```
test-capability-execution-generation12-packaging.sh     6 failures
test-capability-execution-generation13-packaging.sh    12 failures
test-capability-execution-generation13-installer.sh     the installed library holds 73, expected 70 + 1
test-capability-execution-generation14-installer.sh    31 failures
test-capability-execution-helper-ceremony.sh            the pre-ceremony fixture could not be built
test-capability-execution-bb-helper-ceremony.sh         compatibility verdicts INVERTED
```

Everything else passes. Across all 117 suites run individually:

```
108 PASS    3 HOST_ONLY_SKIP    6 FAIL
```

This is **defect B of §5 in six more places** — the same host-following
coupling, in suites this checkpoint was not asked to touch.
`generation12-packaging` already implements the right pattern
(`successor_creates()` reads successor matrices); it simply lists
`install-generation-13.sh` and `install-g11-ax-helpers.sh` and not
`install-generation-15.sh`. The others need more than a name added, including
one that asserts the live host is wholly at one of two declared generations.

**I did not fix them here.** Doing it properly means the same RED-first,
mutation-tested treatment I gave the Generation-15 fixture, across six suites
with different reconstruction models, and doing it hastily risks quietly
weakening historical guarantees to make a gate go green. It is a checkpoint of
its own.

### 7.2 One of the five is on the critical path — read this before Phase 8

`test-capability-execution-bb-helper-ceremony.sh` is the suite that proves the
**helper ceremony**, which is the next step in the deployment plan. It builds its
fixtures the same way the Generation-15 suite did — path set from the live
runtime — so now that the host carries Generation 15's two CREATE objects, its
"Generation 14" fixture is not Generation 14, and its compatibility matrix comes
out inverted:

```
FAIL: B: Gen-15 with old helpers reports compatible      (must be incompatible)
FAIL: E: the complete target reports incompatible        (must be compatible)
FAIL: D: partial set 000 reports compatible
FAIL: D: complete set 111 reports incompatible
```

**These are fixture artefacts, not a finding about production.** The live host,
asked through its own installed rule, answers correctly: `incompatible`, 3
blocking, `supervision_ready` false. Cases B and E were genuinely proven in BB-J
against a fixture that was accurate at the time.

But the proof no longer reproduces, and a ceremony whose suite does not
reproduce is not a proven ceremony. **The helper ceremony should not be run on
the strength of BB-J's evidence until this suite is repaired and green against a
Generation-15 host.** That repair is the recommended next checkpoint, ahead of
Phase 8.

**GitHub CI does not cover this.** All three are host-only, and
`tests/host-only.manifest` says so in terms: *"The local validator is the
authority for everything listed here, and GitHub CI proves none of it."* So
`GITHUB_CI = 6/6` is true and is **not** evidence that these three suites pass.

```
LOCAL_QUICK  FAIL at step 15/108   pre-existing, host-generation coupling
LOCAL_FULL   FAIL at step 15/133   pre-existing, same cause
all suites   108 PASS / 3 SKIP / 6 FAIL, run individually
```

## 8. Production state

Unchanged by this work. No privileged command was run and none succeeded;
`sudo` is password-gated non-interactively for the coordinator.

```
flat library            81                      as the committed transaction left it
CINV-000001             1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV count              1        CRES count 0   CINV-000002 unspent
helper compatibility    incompatible, 3 blocking, supervision_ready false
```

`PRODUCTION_MUTATION_FROM_FIX = NONE`.

## 9. Operator reverify — read-only, against the already-committed state

`--verify-installed` reads. It opens no transaction, publishes no object, writes
no evidence, and touches no grant. Run it from the pinned checkout at the fix
commit.

```bash
set -Eeuo pipefail
cd /opt/schott-platform

# The reviewed artefact, not a local edit.
git rev-parse HEAD                      # expect 51e1c2149076eceee20b0e34e8352a53ec8f59ad
git status --porcelain                  # expect empty
sha256sum provisioning/execution/install-generation-15.sh
# expect 1f74326bbe01c24084cb630bdfaad356f67fc6beaae6d3e4b3ea61afc59f5e5c

# The transaction is COMMITTED and must stay that way. This is a read.
sudo sed -n 's/^state=/journal state: /p' /root/kyri-gen15-transaction/journal

# The verdict.
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh \
     --verify-installed

# The intermediate state must still be the fail-closed one.
sudo env PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys; sys.path.insert(0, "/usr/lib/kyri/python")
from tools.capability.execution import helpers
c = helpers.compatibility()
print("verdict:", c.verdict, "| declared:", len(helpers.REQUIRED_HELPERS),
      "| blocking:", len(c.blocking))
for h in c.blocking: print("   ", h.state, h.path)'
```

### Required results

| expectation |
| --- |
| `journal state: COMMITTED` |
| `--verify-installed` **passes** — no `kyri_exec_reconcile.py`, `kyri_exec_transition_action.py`, `kyri_exec_transition.py` or `kyri_exec_verify.py` in the output |
| the carryover line names the accepted predecessor as Generation 14 **plus 4** ceremony-published objects |
| verdict `incompatible`, 8 declared, **3 blocking**, each `stale` |
| no new `CINV`, no `CRES`, no container, no sudoers change |

**If `--verify-installed` still refuses: STOP** and return the output. Do not
run `--install`, `--recover`, or the helper ceremony.

## 10. Next

**No second `--install` is authorized and none is provided.** The fix changes
only how the installed set is judged; it publishes nothing.

Still prohibited until separately authorized: installing helpers, modifying
sudoers, renewing Fabric, touching `CINV-000001`, spending `CINV-000002`.

```
HELPER_INSTALL_AUTHORISED NO    PRODUCTION_INVOKE_AUTHORISED NO
CINV_000001_FINAL_CLASSIFICATION UNRESOLVED    CINV_000001_RESUME_AUTHORISED NO
```
