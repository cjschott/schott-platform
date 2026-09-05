# ENG-0005 G11-BB-G — E2E verification, and the gates still open

**Status: partial. Phases 1–4, 5A and 9 complete; 5B, 6, 7 and 8 are not.**
Production untouched. `CINV-000001` byte-identical, `CINV-000002` unspent.

Branch `arch/eng-0005-execution-transition`, HEAD `b1359f7`.

---

## 0. What this report does and does not claim

Nine phases were set. **Six are done or materially done; three are not, and I
am not going to describe them as done.** The honest split:

| phase | state |
| --- | --- |
| 1 absent-container reconciliation E2E | **PASS** — real containers |
| 2 full supervised success E2E | **PASS** — real containers |
| 3 recovery E2E, supervised orphan | **PASS** — new, real container |
| 4 defect-class sweep closure | **PASS** — 0 live, 0 latent |
| 5A launch-cli stale invariant | **PASS** |
| 5B g5-preflight successor-awareness | **NOT DONE** |
| 6 full validation green | **BLOCKED by 5B** |
| 7 Generation-15 declaration | **NOT DONE** |
| 8 three-object helper ceremony | **NOT DONE** |
| 9 window decision | **PASS** — and it changes the plan |

## 1. Phases 1–3 — the E2Es, against real containers

The container suites run genuinely: they load the governed image
`5cee2b53…` from the exported OCI archive into a disposable Podman store. The
credential drop is the one thing not exercised — it needs root and would drive
rootless Podman into the production graphroot — and the suites say so.

**Phase 1, absent-container reconciliation** — `test-capability-execution-reconciliation.sh`
passes: orphan reproduction, governed reconciliation, **idempotence (absence is
success)**, name-is-not-identity refusals, closed input.

**Phase 2, full supervised success** — `test-capability-supervised-execution-e2e.sh`
passes: supervised success against a real container, a workload producing
nothing yielding `result-missing`, worker SIGKILL, cleanup that cannot be proven
not being claimed, readiness gating.

**Phase 3, the supervised orphan** — this was the real gap, and it is now
closed. PART 5 of that suite only ever used `adapter_identity`, the *locally
executed* signature. **The shape G11-BB actually hit was never exercised.** New
PART 6 builds it: a real lifecycle journal driven to `launch_authorized`, a
`CINV` with a null adapter identity, and a real container orphaned by killing
the worker.

```
ok  the journal reached launch_authorized
ok  a real container was left behind
ok  without lifecycle authority the orphan is invisible      <- the defect, pinned
ok  with lifecycle authority it is discovered
ok  and it is discovered by state, not adapter identity
ok  readiness stays refused while disposal is unproven
ok  the container is still running at that point
ok  readiness after governed reconciliation
ok  the orphan was stopped and removed
ok  no result was synthesised for it
ok  a reserved-only invocation is not unresolved
```

No manual Podman action appears anywhere in it — the container is removed only
by governed reconciliation.

**The identity-reader and launcher-diagnostic requirements** from Phase 1 are
covered by `test-capability-execution-authority-anchor.sh` (20 assertions),
including the bounded negative diagnostic: a real refusal survives into the
excerpt, control characters are stripped, an enormous stderr is bounded, and the
launcher still refuses.

## 2. Phase 4 — sweep closure

```
SAME_DEFECT_CLASS_LIVE_WRONG   = 0
SAME_DEFECT_CLASS_LATENT_WRONG = 0
```

| site / function | root and authority | flags now | enumeration needed | class | covered by |
| --- | --- | --- | --- | --- | --- |
| `kyri-exec-worker.py:378` main anchor | handoff root `0711` | `O_PATH` | no | fixed | handoff-root-traversal |
| `transition-action.py` `SystemBackend.open_directory` → `_read_authority` | `/etc/kyri` `root:root 0711` | `O_PATH` | no | fixed | authority-anchor |
| same seam → `authenticate_launch` | execution root `0700` | `O_PATH` | no | fixed | authority-anchor, transition-action |
| same seam → `authenticate_profile_source` | handoff root `0711` | `O_PATH` | no | fixed | authority-anchor, profile-transport |
| `kyri-exec-quota.py:151` | handoff root `0711` | `O_PATH` | no | fixed | quota |
| `kyri-exec-verify-worker.py:164` | handoff root `0711` | `_DIR_FLAGS` | no | **deferred** | — |
| `identity.py:250` | opens the **file** by path | `O_RDONLY` | n/a | SAFE | identity-authority |
| `cli.py:324` coordinator reader | opens the **file** | `O_RDONLY` | n/a | SAFE | coordinator-authority |
| `cli.py` `_anchored` roots | runtime store / handoff, **owner** | `_DIR_FLAGS` | no, but owner holds read | SAFE | launch-cli |
| `worker.py` `verify_handoff`/`verify_execution` children | `<CINV>` `0555` | `_DIR_FLAGS` | **yes** | READ_ACTUALLY_REQUIRED | worker-binding, e2e |
| `snapshot.py` package walk and cleanup | package subtree, snapshot dir | `_DIR_FLAGS` | **yes** | READ_ACTUALLY_REQUIRED | lifecycle, cleanup |
| `state.py`, `mutation.py`, `capacity.py`, `admin.py`, `quarantine.py`, `handoff.py` | runtime store `0700`, owner | `_DIR_FLAGS` | **yes** for several | SAFE | capacity, admin, quarantine |
| `trusted_source.py` | payload root, owner `0700` | `_DIRECTORY_FLAGS` | no, owner holds read | SAFE | launch-cli, invoke |
| `image_store.py` | worker's own `HOME` | `_DIR_FLAGS` | yes | SAFE | e2e |
| `implementation_authority.py`, `package_contract.py`, `package_resolution.py` | coordinator-owned | `_DIR_FLAGS` | yes | SAFE | authority-resolution |

**`READ_ACTUALLY_REQUIRED` sites are unchanged**, as required. Nothing was
blanket-replaced.

**The deferred verification surface, explicitly.** `kyri-exec-verify-worker.py`
still carries the read-mode anchor. It remains deferrable because it is still
**unreachable and ungranted**: `/etc/sudoers.d/kyri-exec-verify` is absent
(verified this session), and the runtime module it loads is the stale
`verification.py` from BA §0.1, so the entrypoint cannot run even if it were
granted. It is recorded here rather than fixed, and it must be corrected in the
same checkpoint that repairs the verification surface — before that grant is
ever installed.

## 3. Phase 5A — the stale launch-cli invariant

`assert os.listdir('/data/kyri/capability-handoff') == []` encoded the claim
that production has never been invoked. `CINV-000001` permanently falsified it.

**Evidence was not rewritten to fit production.** The suite already proves it
mutates nothing, properly, with a before/after snapshot of every production path
covering mode, owner, size and both timestamps. The stale line was redundant as
well as wrong. It is replaced with the narrower claim that is still true and
still worth making: **no fixture invocation may appear in the production
handoff**. `CINV-000001` is neither hidden nor required absent.

`test-capability-execution-launch-cli.sh` passes.

## 4. Phase 9 — the window, and what it implies

```
host now                     2026-09-05T10:51:32-05:00
CADV-000004.valid_until      2026-09-06T12:02:14-05:00
CINST-000003.admitted_until  2026-09-06T12:02:14-05:00
WINDOW_REMAINING             25h 10m   (90641 s)
```

**`CHAIN_RENEWAL_BEFORE_CINV_000002 = YES`.** This is the recommendation, and
the window is not the main reason — the remaining work is.

Still outstanding before a production invoke: Phase 5B, a Generation-15
declaration and installer with a crash/recovery matrix, a three-object helper
ceremony, full validation, CI, then post-install acceptance, then a fresh
selection, then a three-stage `CINV-000002` ceremony. That is several governed
checkpoints. Twenty-five hours would be tight even if everything were built and
green, and none of it should be hurried to beat an expiry.

The chain is cheap to renew and the renewal is already a well-rehearsed
ceremony — G11-AY through G11-AZ did it four times. **Renew after the corrected
execution surface is deployed and accepted**, not before, so the new
`CADV`/`CINST`/`CROUTE`/`CSEL` opens its window against a platform that can
actually execute.

`CINV-000002` is not spent, and must not be spent to preserve the current
window.

## 5. What is not done, and what it needs

### 5B — `g5-preflight` successor-awareness  **NOT DONE**

`tests/test-capability-execution-g5-preflight.sh` fails, and **it was already
failing before any of this correction work**: 18 suite-level failures at
`3636976`, 5 now. My changes reduced it. It is a pre-existing broken gate, not a
regression — but it is a real gate and it blocks validation.

The declaration in `provisioning/execution/g5-preflight.sh` models a transition
as *pending* or *applied* against one predecessor. It has no vocabulary for
"this object is a known successor source ahead of the installed generation",
so it reports every such object as undeclared drift. Making it distinguish

```
accepted installed predecessor  |  known successor source  |  actual unknown drift
```

is a genuine design change to a 709-line governed artefact, not a digest
refresh. **Refreshing the digests would be exactly the "rewrite evidence to fit
production" this checkpoint forbids**, so I did not do that.

### 6 — validation  **BLOCKED**

`tools/dev/run-validation.sh --quick` halts at step 35 on 5B. Everything before
it passes. `LOCAL_FULL` and `GITHUB_CI` were therefore not run to completion; I
am not going to report a colour for them.

### 7 — Generation 15  **NOT DONE**

The runtime delta **is** derived, against the installed Generation 14:

```
GEN15_REPLACE (4 objects, all REPLACE, no CREATE):
  tools/capability/cli.py                        752951f7688a -> 7b4fac3e8543
  tools/capability/execution/recovery.py         a93819d1400d -> f44ada7f3272
  tools/capability/execution/helpers.py          74b84015b18a -> 6dd936064f1c
  kyri_exec_launcher.py                          269258f3a407 -> 78c6de9093a5
GEN15_CREATE     none
GEN15_CARRYOVER  the remaining 75 library objects
```

Four objects, matching the expectation — **derived, not assumed**. What is not
built is `install-generation-15.sh` itself: `--verify`, fixture `--install`,
fixture `--verify-installed`, the crash/recovery matrix, unknown-byte refusal.
The Generation-14 installer is 1141 lines and its structure is not boilerplate.

### 8 — helper ceremony  **NOT DONE**

The delta **is** derived — exactly three objects, matching the expectation:

```
provisioning/execution/kyri-exec-worker.py             2d320630aca559c7…
provisioning/execution/kyri-exec-transition-action.py  b11a2f19bc469ae4…
provisioning/execution/kyri-exec-quota.py              54a9b15c6c6e3b78…
```

**The sudoers claim is proved, not asserted.** The two grants pin
`/usr/libexec/kyri-exec-transition` (`0d9c8d8c…`) and
`/usr/libexec/kyri-exec-reconcile` (`2878fff0…`). Neither entrypoint file is in
the delta; both digests are unchanged and still match the installed bytes,
verified this session. The three changed objects are loaded *by* those
entrypoints after elevation and are not sudo targets. **No sudoers change.**

The fail-closed sequencing requirement is already demonstrated rather than
promised: the repository reports `incompatible / stale` for the three helpers
against installed Generation 14 while production reports `compatible`. A partial
install cannot report compatible, because `helpers.py` (a Generation-15 object)
carries the declaration and the two must land together. What is not built is the
ceremony script that installs them as one transaction.

## 6. Production state

```
CINV-000001   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CRES          0 records
fabric        7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
libexec       489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86   unchanged
/etc/kyri     root:root 0711        unchanged
handoff root  cschott:cschott 0711  unchanged
```

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 7. Next

1. **Phase 5B** — make the `g5-preflight` declaration successor-aware. It gates
   validation and it is already red independently of this work, so it is the
   first thing that must move.
2. **Phase 6** — full validation and the six workflows, once 5B lands.
3. **Phase 7 / 8** — build `install-generation-15.sh` and the three-object
   helper ceremony against the deltas derived in §5, which are settled.
4. **Then** deployment, acceptance, chain renewal, and only then a
   `CINV-000002` ceremony.
