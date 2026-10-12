# ENG-0005 G11-BB-E — corrections B and D, implemented

**Status: implemented in the repository, not deployed. Production untouched.**
No `execute`, no `recover`, no privileged helper, no Podman, no permission
change. `CINV-000001` is byte-identical, `CINV-000002` unspent.

Follows **[G11-BB-D](2026-09-04-g11-bb-d-stage-3-unresolved-root-cause.md)** and
the reviewer rulings recorded there.

Branch `arch/eng-0005-execution-transition`, HEAD `d11e141`.

---

## 0. Reviewer rulings, recorded

```
CINV_000001_RESUMABLE_BY_STATE_MACHINE  YES
CINV_000001_RESUME_AUTHORISED           NO
CINV_000001_FINAL_CLASSIFICATION        UNRESOLVED
EXECUTE_RETRY_AUTHORISED                NO
SYNTHETIC_CRES_AUTHORISED               NO
HANDOFF_PERMISSION_CHANGE_AUTHORISED    NO
RECOVERY_DISCOVERY_GAP                  CONFIRMED
FIX_REQUIRED_BEFORE_NEXT_PRODUCTION_INVOKE  YES
```

`CINV-000001` is preserved byte-for-byte as the historical first production
execution attempt. The next attempt uses `CINV-000002`, which is not spent.

Scope items **A** (reconciliation root cause) and **C** (its fix) remain blocked
on the authorised operator diagnostic — §4. **B** and **D** are complete. **E**
is derived below. **F** and **G** follow.

## 1. Correction B — the handoff root anchor

**The governed mode is unchanged and must stay `0711 cschott:cschott`.**

`provisioning/execution/kyri-exec-worker.py`:

```python
_DIR_FLAGS    = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_ANCHOR_FLAGS = os.O_PATH   | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
...
handoff_fd = os.open(worker.HANDOFF_ROOT, _ANCHOR_FLAGS)
```

`O_RDONLY` on a directory asks for **read**, which design §13 deliberately
withholds. `O_PATH` asks for what `openat` actually needs — **search** — and
`0711` grants exactly that.

**The no-enumeration property is now stronger, not weaker.** An `O_PATH`
descriptor cannot be read at all, so sibling enumeration is impossible by
construction rather than by permission. A widened mode would have satisfied the
worker and quietly destroyed the property the design names.

Only the parent anchor changed. `_DIR_FLAGS` is unchanged everywhere else,
including the `out` directory open, and the three `openat` call sites are
untouched.

### 1.1 A latent instance left alone

`provisioning/execution/kyri-exec-quota.py:151` opens `HANDOFF_ROOT` with the
same read-mode flags. **It is latent, not live**, and I verified why:
`perform_transition` calls `quota.apply()` *"Before any privilege is spent"* —
above `drop_privilege` — so it runs as root, and root bypasses the directory
permission check. That is also why Stage 3 got past quota and died in the
worker.

It is **not changed here**. It is not broken, and widening this correction to a
second declared helper would enlarge the ceremony for no current defect. It is
recorded so the reviewer can rule: including it would cost little, since a
helper ceremony is already required, and it would remove a defect that becomes
live the moment the quota step ever moves below the drop.

The same pattern in `kyri-exec-verify-worker.py:164` belongs to the deferred
verification-surface remediation (BA §0.1) and is untouched.

## 2. Correction D — supervised recovery discovery

**Not by making `CINV` mutable and not by back-filling `adapter_identity`**, as
the ruling required. Both would destroy the property that makes an interrupted
execution attributable: the record is written before the adapter precisely so a
crash mid-flight is still evidence.

Discovery now reads the **lifecycle transition journal** — immutable governed
execution state that `authorise_launch` writes before the privileged boundary is
crossed, which is exactly the authority the ruling pointed at.

`tools/capability/execution/recovery.py`:

```python
_CONTAINER_POSSIBLE_FROM = LifecycleState.LAUNCH_AUTHORIZED

def unresolved_invocations(store, *, execution_root=None):
    ...
    if not adapter_identity and not _container_possible(state):
        continue
```

**`launch_authorized`, not `created`.** The container is created by the worker on
the far side of the privilege drop, and the state advances to `created` only
once the coordinator learns of it. Between those two facts a container can exist
that no state records, so the conservative boundary is the last state the
coordinator wrote before handing over.

**Neither signature is dropped.** An invocation qualifies on `adapter_identity`
*or* on lifecycle state, so the locally executed path keeps exactly the
behaviour G11-AO gave it. `execution_root` is optional, so a caller without a
journal gets the original answer rather than an error.

`Unresolved` gained `lifecycle_state` alongside `adapter_identity`, so a finding
says *why* it was discovered. `reconcile_unresolved` and `execution_safety`
thread the root through; `command_recover` opens
`/data/kyri/capability-runtime/execution` as a verified root descriptor and
closes it in a `finally`.

**Applied to the live incident:** `CINV-000001` is at `launch_authorized` with
no terminal result, so it *would* now be discovered — where before it was
invisible. That does not authorise running `recover`, which remains withheld.

## 3. Tests — RED-first

Two new suites, both unprivileged and isolated: no sudo, no helper, no Podman,
no production path.

**`tests/test-capability-execution-handoff-root-traversal.sh`** (committed with
BB-D) builds the production shape mode for mode and copies the worker's flags
verbatim:

```
ok    O_RDONLY|O_DIRECTORY on a traverse-only parent is refused   <- the failure
ok    O_PATH open of a traverse-only parent succeeds
ok    openat(root_fd, CINV) reaches the child
ok    the parent still cannot be enumerated                       <- the property
```

**`tests/test-capability-execution-recovery-discovery.sh`** builds a verified
execution root the way the capacity suite does, drives
`reserve → launch_authorized`, and pins six properties including the regression
itself:

```
ok    a supervised launch_authorized invocation is discovered
ok    and it is reported by lifecycle state, not adapter identity
ok    without the journal the same invocation is invisible (the old defect)
ok    a local adapter invocation is discovered without a journal
ok    a local adapter invocation is discovered with a journal too
ok    a reserved-only invocation is not discovered
ok    an invocation with a terminal result is not discovered
ok    the safety gate wrote nothing
```

The third assertion is deliberate: it pins the defect so a future refactor
cannot quietly reintroduce it.

**Every affected suite passes**, including `supervision`, `supervised-execution-e2e`,
`reconciliation`, `lifecycle`, `capacity`, `cleanup`, `worker-binding`,
`runtime`, `generation13-installer`, `generation14-installer` and
`generation14-readiness`.

## 4. Blocked — reconciliation (A and C)

Still not root-caused, and the authorised diagnostic has not been run because
this session cannot invoke `sudo` non-interactively. The command is in BB-D §4.5
and is repeated in §7 below.

What is established: `reconcile()` is idempotent and returns `final_absent: true`
for an absent container rather than raising, so the failure occurred before it
returned; every earlier path raises `SystemExit("refused: …")` to **stderr**,
leaving stdout empty; and `HelperLauncher.reconcile` discards `done.stderr`, so
the real reason was lost. The leading hypothesis remains `use_pty` merging
streams and corrupting the JSON, which `cat -A` on both streams will settle.

**C is not attempted before A.** Fixing the launcher's error reporting before
knowing what it hid would be guessing at the fix.

## 5. Correction class and ceremony boundaries — item E

| change | file | class |
| --- | --- | --- |
| B — handoff anchor | `provisioning/execution/kyri-exec-worker.py` | **helper ceremony** |
| B — declared digest | `tools/capability/execution/helpers.py` | **runtime generation** |
| D — discovery | `tools/capability/execution/recovery.py` | **runtime generation** |
| D — root threading | `tools/capability/cli.py` | **runtime generation** |

```
CORRECTION_CLASS         multiple (helper ceremony + runtime generation)
HELPER_CEREMONY_REQUIRED YES   — one object: /usr/libexec/kyri-exec-worker.py
NEXT_GENERATION          15    — Generation 14 + 3 library objects
SUDOERS_CHANGE           NONE  — no pinned entrypoint digest moves
DEPLOYMENT_STORAGE       NONE  — 0711 is correct and stays
```

**The sudoers grants are unaffected**, and this is worth stating precisely: the
pinned digests are `kyri-exec-transition` and `kyri-exec-reconcile`, neither of
which changed. `kyri-exec-worker.py` is loaded *by* the transition after the
drop; it is not a sudo target.

### 5.1 The ordering constraint, now demonstrated

`helpers.py` declares the worker's digest, and
`tests/test-capability-execution-supervision.sh` holds the table to the sources
it names. Changing the worker without the declaration failed that suite with
*"the declaration is stale"* — the check doing its job.

The consequence is visible right now:

```
installed Generation-14 runtime :  compatible    0 blocking
repository runtime              :  incompatible  1 blocking — stale /usr/libexec/kyri-exec-worker.py
```

**Both answers are correct.** Production is self-consistent and untouched; the
repository correctly refuses to supervise through a worker it no longer
declares. **The two changes must be installed together**, and a partial install
fails closed rather than silently — which is the G11-AI defect class this
machinery exists to defeat.

## 6. Production state — unchanged

```
CINV-000001   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CRES          0 records          capability-result.seq  ABSENT
transitions   CINV-000001.000001 (reserved), .000002 (launch_authorized)
handoff root  cschott:cschott 0711                     unchanged
libexec       489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86  unchanged
runtime lib   5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84  unchanged
fabric        7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96  unchanged
sudoers       f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9  unchanged
```

`PRODUCTION_MUTATION = NONE`. `CINV_000002_SPENT = NO`.

## 7. Next — the authorised diagnostic

Read-only, idempotent, creates no container, writes no governed record.
Authorised by the reviewer for `CINV-000001` only.

```bash
sudo /usr/libexec/kyri-exec-reconcile CINV-000001 \
  > /tmp/reconcile.out 2> /tmp/reconcile.err ; echo "rc=$?"
echo "--- stdout (cat -A shows \r, which distinguishes the hypotheses) ---"
cat -A /tmp/reconcile.out | head -20
echo "--- stderr ---"
cat    /tmp/reconcile.err | head -20
```

- **stdout carries valid JSON with `final_absent: true`** → reconciliation
  works; the earlier failure was transport, and `use_pty` stream-merging is the
  live hypothesis. Fix C is then in `HelperLauncher.reconcile`.
- **stdout empty, stderr carries `refused: …`** → that message is the root
  cause, and fix C addresses both it and the discarded-stderr masking.

Do **not** run `capability recover`. Do not re-run `execute`.

## 8. Remaining scope

```
A  reconciliation root cause              BLOCKED on §7
B  worker anchor                          DONE
C  reconciliation reporting/launcher       BLOCKED on A
D  supervised recovery discovery           DONE
E  ceremony boundaries                     DERIVED — §5
F  fixture E2E                             PENDING — worker failure, absent-container
                                           reconcile, orphan recovery, successful run
G  production deployment preparation       PENDING
```

**F cannot be finished before A**, since one of its four scenarios is
absent-container reconciliation. The other three are reachable now.
