# ENG-0005 G11-BC-A — the recovery-discovery key, corrected

**Status: the defect G11-BB-Z blocked on is fixed at its source. Recovery
discovery now keys the lifecycle journal by the record identity, both production
invocations are discovered, and the execution-safety gate inspects them instead
of passing vacuously.**

**The fix changes an installed Generation-15 runtime object.** It is not
deployed by this checkpoint, and deploying it needs a Generation-16 runtime
ceremony — `recovery.py` sits in Generation-15 coherence group `R`.

**Local validation is RED, and deliberately so** — the G5 preflight refuses a
checkout carrying an undeclared successor to a generation-declared object (§9.1).
That refusal *is* the deployment rule, working.

```
RECOVERY_DISCOVERY_FIX          PASS      EXECUTION_SAFETY_FIX  PASS
OPAQUE_INVOCATION_ID_REGRESSION PASS      RECOVERY_E2E          PASS
SAME_DEFECT_CLASS_LIVE_WRONG    0         LATENT_WRONG          0
RUNTIME_BYTES_CHANGED           YES       DEPLOYMENT_REQUIRED   YES
DEPLOYMENT_CLASS                GENERATION_16_RUNTIME_CEREMONY
SUDOERS_CHANGE_REQUIRED         NO
STAGE3_AUTHORISED               NO
```

Branch `arch/eng-0005-execution-transition`. No production state was changed; no
execution, no recovery, no container.

---

## 1. Root cause

`authorise_launch` transitions on the **`CINV`**, so the lifecycle journal is
keyed by the record identity. `_invocation_identity` preferred the **opaque**
`invocation_id`:

```python
return record.get("invocation_id") or record.get("invocation_record_id")
```

On every real invocation those are different strings — `CINV-000002` against
`g11bb2-second-controlled-invoke` — so `states.get(identity)` missed, the state
read `None`, `_container_possible(None)` was false, `adapter_identity` is `None`
on the supervised path, and the record was skipped.

**The same value is handed to the reconciler**, which makes the consequence
worse than a missed lookup. `reconcile_unresolved` does `cinv =
invocation.invocation_id` and calls `reconciler(cinv)`; `launcher.reconcile`
validates the canonical CINV shape — the same shape the sudo grant pins — so an
opaque identity would have been refused before reaching Podman. The invocation
could not have been reconciled even if it had been found.

The `or …invocation_record_id` fallback rescued only records whose opaque id was
absent, which is why fixtures that set the two equal never saw it.

## 2. RED first

Nineteen assertions in `tests/test-capability-execution-recovery-discovery.sh`,
eight of them new and failing before the fix:

```
FAIL  a supervised invocation with an OPAQUE invocation_id is discovered
FAIL  and it is reported at its journal lifecycle state
FAIL  the identity carried for reconciliation is the CINV, not the opaque id
FAIL  reconciliation is asked about the CINV
FAIL  and the reconciled invocation stops blocking
FAIL  an unproven supervised invocation is INSPECTED, not skipped
FAIL  and blocks readiness until disposal is proven
FAIL  readiness returns only after the invocation was actually checked
```

The eleven pre-existing assertions passed throughout, so the old working shape
stays covered. The fixture helper now takes the opaque id explicitly and
documents why the default is a convenience rather than the production shape:

```python
def invocation(cinv, adapter_identity=None, invocation_id=None):
    """...`invocation_id` is the OPAQUE, operator-supplied identity and is a
    different thing from `invocation_record_id`. ... A fixture that always made
    them equal is what let the G11-BB-Z defect survive this suite."""
```

**No vacuous pass.** The safety assertions distinguish *ready because checked*
from *ready because nothing was looked at*: a refusing reconciler must produce
`NOT_READY` with `checked == 1`, a proving one `READY` with `checked == 1`, and
an empty store `READY` with `checked == 0`.

## 3. The fix

One function, at the source of the mismatch:

```python
def _invocation_identity(record: Any) -> Any:
    """The `CINV` reconciliation takes, and the lifecycle journal is keyed by.
    ...
    Two downstream facts settle which belongs here, and both want the record's.
    `authorise_launch` transitions on the `CINV`, so the journal this identity
    is looked up in is keyed by it. And `reconcile_unresolved` hands this value
    to the reconciler, which validates `^CINV-[0-9]{6}$` -- the same shape the
    sudo grant pins -- so an opaque identity could not be reconciled even if it
    were found.
    """
    return record.get("invocation_record_id") or record.get("invocation_id")
```

`CINV` stays immutable, nothing is backfilled, journal keying is untouched, and
no adapter identity is synthesised. `_invocation_identity` has **exactly one
caller** (`recovery.py:222`) and its own docstring already declared it returns
the CINV, so this is the source of the mismatch rather than a blanket rename.

Both consumers of the value want the record identity: `reconcile_unresolved`
passes it to the reconciler, and `command_recover` reports it. Nothing else
reads it.

## 4. Proof against live production, read-only

The corrected code, run against the real store and the real journal. **No
reconciler was invoked and `execution_safety` was not called against
production:**

```
CINV-000001  invocation_id='CINV-000001'  adapter_identity=None  lifecycle_state=launch_authorized
CINV-000002  invocation_id='CINV-000002'  adapter_identity=None  lifecycle_state=launch_authorized
```

Both are now discovered, at their real lifecycle state, carrying the CINV.
Before the fix this returned `()`.

### 4.1 What this changes on production, once deployed

`execution_safety` is called from exactly one place — `command_recover`
(`cli.py:753`). **`command_execute` does not consult it**, so this does not gate
Stage 3.

What changes is that `capability recover` stops being vacuous: it will discover
both invocations, invoke the privileged reconciliation helper for each, and
report `NOT_READY` until each proves `final_absent`. That is a real privileged
action and needs its own authorisation. Reconciliation resolves the *container*,
not the invocation — `command_recover` "writes nothing … the invocation record is
never touched" — so it does not resume, retry or resolve `CINV-000001`, whose
classification stays permanently UNRESOLVED.

## 5. Real-container E2E

`tests/test-capability-execution-reconciliation.sh` gains a Part 4b that wires
the whole path together on a **real orphaned container** in the suite's
disposable Podman store, with the production record shape and the **real**
reconciler — not a stub:

```
invocation_record_id  CINV-000044            <- what the journal is keyed by
invocation_id         g11bbz-opaque-invoke   <- what the operator supplied
adapter_identity      None                   <- the supervised path never writes it
```

```
journal keyed by the CINV                      PASS  launch_authorized
a real orphan is running                       PASS  'running'
discovered by record id                        PASS  ['CINV-000044']
carried for reconciliation as the CINV         PASS  ['CINV-000044']
an unproven orphan is inspected, not skipped   PASS  ['CINV-000044']
readiness blocked while disposal is unproven   PASS  'not-ready'
and it is reported as blocking                 PASS  ['CINV-000044']
a refusal disposes of nothing                  PASS  'running'
the real reconciler was asked about the CINV   PASS  ['CINV-000044']
the orphan was stopped and removed             PASS  'absent'
readiness returns after governed cleanup       PASS  'ready'
having checked the invocation, not skipped it  PASS  1
nothing is left blocking                       PASS  ()
a second pass is idempotent                    PASS  'ready'
and still inspected the invocation             PASS  1
```

That the **real** reconciler accepts the identity is itself the proof that a
canonical CINV is what gets handed over; an opaque id would have been refused
before Podman was reached.

**One assertion of mine was wrong and the run caught it.** I first asserted that
`execution_safety` reports `NOT_READY` while a real orphan runs. It does not —
`execution_safety` *proves* absence by reconciling, so the call that observes the
orphan is also the call that disposes of it. Blocked is the state when
reconciliation cannot prove absence. The case now drives a refusing reconciler
against the live orphan, checks the container survives untouched, and only then
proves disposal with the governed one. The corrected shape is stronger than what
I first wrote.

## 6. Same-defect sweep

Every site where lifecycle state is indexed or joined to an invocation record.

**The structural finding that closes the sweep:** `state.py` calls
`validate_cinv(cinv)` on every entry point — `current_state`, `transition`,
`transition_locked`, and the keys `all_states` returns. So any caller passing an
opaque identity **raises** rather than silently missing. The only place the value
was used as a bare `dict.get(...)` key — where a mismatch degrades to silence
instead of an error — was `recovery.py:222`.

| site | classification |
| --- | --- |
| `recovery.py:222` `_invocation_identity` → `states.get(...)` | **LIVE_AND_WRONG → fixed** |
| `recovery.py:254` `cinv = invocation.invocation_id` → `reconciler(cinv)` | **LIVE_AND_WRONG → fixed by the same change** |
| `cleanup.py:225,227,258` | SAFE — `validate_cinv` before `current_state`/`transition` |
| `cleanup.py:276` | SAFE — `validate_cinv` |
| `cleanup.py:330` `all_states(root).items()` | SAFE — iterates journal keys; no join to records |
| `quota.py:67` | SAFE — `validate_cinv` |
| `launch.py:367,402,405,412,478` | SAFE — `_require_cinv` before `current_state`/`transition` |
| `inspection.py` | SAFE — no lifecycle join at all |
| `tools/trust/*` `current_state` | DIFFERENT_SEMANTICS — Trust lineage state (`trusted`, `quarantined`, `revoked`, …), a different enum on a different plane |

```
SAME_DEFECT_CLASS_LIVE_WRONG    0
SAME_DEFECT_CLASS_LATENT_WRONG  0
```

No blanket replacement was made: `coordinator.py:180,194` and `cli.py:220,391`
carry `invocation_id` on the *invoke* path, where the opaque identity is correct
and stays.

### 6.1 Two supervision assertions encoded the defect

`tests/test-capability-execution-supervision.sh` had two cases that pinned the
wrong behaviour. One is named **"recovery reconciles each unresolved invocation
by CINV alone"** and asserted:

```python
assert clean.calls == ['inv-1', 'inv-4']
```

The name states the correct invariant; the assertion contradicts it. `inv-1` is
not a CINV and `launcher.reconcile` would refuse it. Both are corrected to
assert the CINV, and the fixture helper's second parameter — misnamed `cinv`
when it holds the opaque id, which is plausibly how the wrong assertion got
written — is renamed `opaque` with a comment saying so.

This is correcting a test that asserted a defect, not weakening an invariant:
the record-identity assertions in the same cases are unchanged and still pass.

## 7. Deployment classification

**`recovery.py` is a Generation-15 runtime object.** It is declared in the
Generation-15 matrix:

```
tools/capability/execution/recovery.py | ${LIBRARY_ROOT}/tools/capability/execution/recovery.py
  | 0444 | REPLACE | a93819d1…(predecessor) | f44ada7f…(target) | R
```

```
installed  f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03
corrected  fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0

RUNTIME_BYTES_CHANGED = YES        DEPLOYMENT_REQUIRED = YES
```

**Not a helper ceremony.** `recovery.py` is absent from
`helpers.REQUIRED_HELPERS` (which names the two entrypoints, the two worker
modules and the four flattened privileged modules) and the G11-BB helper matrix
references it zero times.

**Not a narrow patch.** No patch-ceremony mechanism exists in the tree — the
deployment authority is generation ceremonies (`install-generation-5` …`-15`)
and helper ceremonies, and inventing a third is out of scope. So:

```
DEPLOYMENT_CLASS = GENERATION_16_RUNTIME_CEREMONY
```

**The coherence-group constraint the next checkpoint must respect.**
Generation-15 group `R` — "supervised recovery discovery" — has two members:

```
R   tools/capability/execution/recovery.py     <- changes
R   tools/capability/cli.py                    <- unchanged
```

Generation 15's own `--verify-installed` requires "every coherence group is
wholly at one generation (H R V)". Publishing a new `recovery.py` alone would
split group `R`, so Generation 16 must declare the group and move it coherently.
Constructing that ceremony is its own preparation checkpoint's work.

### 7.1 SUDOERS_CHANGE_REQUIRED = NO, proved

The two grants pin the two entrypoints by digest, and neither changes:

```
/usr/libexec/kyri-exec-transition   0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
/usr/libexec/kyri-exec-reconcile    2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
```

`git status` reports no change under `provisioning/` at all, `recovery.py` is not
an entrypoint, and it is not in `REQUIRED_HELPERS`. The verification grant stays
absent.

```
SUDOERS_CHANGE_REQUIRED = NO
```

## 8. CINV-000002 safety, held throughout

```
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   unchanged
CINV-000001  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
lifecycle    launch_authorized (reserved → launch_authorized, unchanged)
handoff      unchanged            payload  e12a525c…  unchanged
INVOCATION_SEQ 2      CRES_COUNT 0
fabric 3fa32b83…      trust 53605e4e…      both byte-identical

no execute, no recover, no reconciler invoked against production,
no kyri-CINV-000002 container created
```

The E2E's containers are `CINV-000044` in the suite's own disposable Podman
store, torn down by its trap.

## 9. Validation

```
CHANGED
  tools/capability/execution/recovery.py                  +22 -4   (one function + docstring)
  tests/test-capability-execution-recovery-discovery.sh   +90      (8 new assertions)
  tests/test-capability-execution-reconciliation.sh      +132      (real-container Part 4b)
  tests/test-capability-execution-supervision.sh          +12 -4   (two corrected assertions)

FOCUSED SUITES
  recovery-discovery  19/19        reconciliation (real containers)  PASS
  supervision         20/20        lifecycle 45   cleanup 24
  capability-runtime  1089         capacity 31    capacity-race 5
  launch-cli 26       launch-bridge 31
  supervised-execution-e2e PASS    invoke-execution-e2e PASS

shellcheck   clean

LOCAL_QUICK  FAIL at step 35        LOCAL_FULL  FAIL at step 59
             both at the same suite: Capability execution G5 preflight
GITHUB CI    FAIL, same step        CLEAN CLONE  n/a while validation is red
```

All suites are registered in `tools/dev/run-validation.sh`; no new suite was
added.

### 9.1 Validation is red BY DESIGN, and it is the deployment rule enforcing itself

Exactly one suite refuses. `test-capability-execution-g5-preflight.sh` fails,
and the other generation-aware suites — `generation-succession`,
`generation15-installer`, `bb-helper-ceremony` — all pass.

```
FAIL  the declared object tools/capability/execution/recovery.py is fdad3cec…,
      which is not a declared successor (a93819d1…,f44ada7f…)
```

`g5-preflight.sh:624` states the rule: *"The checkout side is absolute: whatever
the installed generation is, the checkout must carry exactly the bytes the row
declares."*

```
declared predecessor  a93819d1400d981097eab6e2f31413ea90bc094d5dfd09265a368ccc0e59ab8f
declared target       f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03
checkout now          fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0
```

**A generation-declared runtime object cannot be corrected in the repository
without a generation declaring the successor.** The §7 classification is
therefore not advisory — the platform enforces it at the checkout, before any
install is attempted. The correction and its Generation-16 declaration are one
indivisible unit as far as validation is concerned.

I did not suppress, skip or relax the check to make the branch green. Declaring
`fdad3cec…` as Generation 16's target for group `R` is the governed way to
resolve it, and building that ceremony is the next checkpoint's work rather than
something to fold into a correction checkpoint for one defect.

## 10. Next

```
STAGE3_AUTHORISED  NO       PRODUCTION_INVOKE_AUTHORISED  NO
CINV_000001_RESUME_AUTHORISED  NO
```

The correction is complete in source but **not deployed**. Stage 3 remains
unsafe to authorise for the reason G11-BB-Z gave: the installed bytes still
carry the defect, so a failed Stage 3 would leave `CINV-000002` undiscoverable
by the governed recovery path.

The next checkpoint is Generation-16 preparation for coherence group `R`.
