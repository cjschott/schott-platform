# ENG-0005 G11-BC-D — Stage 3 unresolved: two root causes, corrected

**Status: both defects are root-caused to source and corrected, with RED/GREEN
evidence. Neither is deployed. Local validation is RED, deliberately — the
corrections change bytes `helpers.py` declares, and that declaration refusing is
the deployment rule working.**

Stage 3 for `CINV-000002` refused twice over: the worker could not open the
handoff's `out` directory, and the reconciliation that followed could not read
container state. They are unrelated defects that happened to fire in sequence.

```
STAGE3_RESULT                UNRESOLVED    result_recorded  false
HANDOFF_OUT_ROOT_CAUSE       the ownership transfer §13 requires is implemented nowhere
RECONCILE_CWD_ROOT_CAUSE     cwd is the one process property the privilege boundary never closed
HANDOFF_SAME_CLASS_LIVE_WRONG  1     LATENT  0
CWD_SAME_CLASS_LIVE_WRONG      3     LATENT  2
DEPLOYMENT_CLASS             BOTH — helper ceremony AND Generation-17 runtime ceremony
SUDOERS_CHANGE_REQUIRED      NO
CINV_000002_RESUME_POSSIBLE  YES (after deployment)   RESUME_AUTHORISED  NO
```

`CINV-000002` is unchanged at `923ff0d7…`, `CRES_COUNT=0`, and no container
exists. Nothing in this checkpoint executed, recovered, reconciled, or mutated
any production state.

---

## 1. Stage 3, accepted as unresolved

```
WorkerRefused: the handoff 'out' is unusable: [Errno 13] Permission denied: 'out'

status           unresolved      result_recorded  false
worker_reaped    true            disposal_proven  false
reconciliation   the container state could not be read: the runtime refused:
                 cannot chdir to /opt/schott-platform: Permission denied
rc               1
```

The shape is exactly what G11-BC-C §7.3 predicted for the unresolved path:
`result_recorded: false`, so **no `CRES` was written**, and the fields that
appear only on that path (`worker_reaped`, `reconciled`, `protocol_states`) are
present. The contract held.

**The refusal happened before any container existed.** `worker_reaped: true` and
no `kyri-CINV-*` container is present, so `disposal_proven: false` reports an
unproven disposal of something that was never created rather than an orphan.

## 2. Root cause 1 — the handoff output leaf

### 2.1 Where the refusal comes from

`worker.verify_handoff` (`worker.py:400`) calls
`_check(OUTPUT_NAME, invocation, directory=True, mode=EXPECTED_MODES[OUTPUT_NAME])`,
and `_check` (`:354`) opens the child:

```python
handle = os.open(name, _DIR_FLAGS, dir_fd=dir_fd)     # O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_DIRECTORY
...
raise WorkerRefused(f"the handoff {name!r} is unusable: {error}")
```

`out` is `cschott:cschott 0700`. The worker runs as uid 999. "Other" gets
nothing, so `O_RDONLY|O_DIRECTORY` returns `EACCES` — the exact production
message.

### 2.2 The mode was never wrong. The owner was never set.

Four independent statements of the intended state, three of them in code:

| source | statement |
| --- | --- |
| design §13 table | `…/<CINV>/out/` → **`kyri-capability:kyri-capability`** `0700` read+write, "the one writable leaf" |
| `handoff.py:22` | "Modes are declared here; ownership is not. … **Transferring the writable leaf to the execution identity is the privileged transition's job**, and doing it here would need authority this module must not have." |
| `worker.py:692` | "`keep-id` maps the invoking user — the worker — onto a chosen container id, so **the worker-owned 0700 output directory** appears inside as owned by the governed container identity and is writable by it" |
| `snapshot.py:112` | "The one handoff path that stays: **the writable output leaf is already worker-owned**" |

`worker.EXPECTED_MODES[OUTPUT_NAME]` is `0o700`, so the worker itself demands
that mode. **0700 is correct.**

```
OUT_DIR_EXPECTED_OWNER  kyri-capability:kyri-capability  (999:987)
OUT_DIR_EXPECTED_MODE   0700
OUT_DIR_ACCESS_NEEDED_BY_WORKER     open O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_DIRECTORY,
                                    fstat (type + mode), and resolve it as a
                                    rootless bind source
OUT_DIR_ACCESS_NEEDED_BY_CONTAINER  read+write, bound rw at /kyri/output under
                                    --userns keep-id, which maps the WORKER onto
                                    the container identity — so it is writable
                                    inside only if the worker owns it outside
```

### 2.3 The transfer is implemented nowhere

```
grep -rn "chown|fchown|lchown" over the whole execution surface
  -> three matches, ALL of them comments saying the module does not chown
  -> ZERO call sites, in the repository and in the installed tree
```

**`handoff.py` declined the job by name and the privileged transition never took
it up.** The step was specified and never written.

### 2.4 Why it belongs in the privileged transition, and not elsewhere

Publication runs as the coordinator, which cannot create a directory owned by
another uid. §34 makes establishing the XFS project on `out/` a *mandatory step
between handoff preparation and the credential drop*, so the directory must
already exist before the worker starts — creation-time ownership, the mechanism
§12 prefers over chowning, is therefore unavailable for this object. The only
privileged step between publication and the drop is the transition, which is
what `handoff.py` already names.

`transfer_output_leaf` is added there: reached descriptor-relatively from the
governed root, opened no-follow, checked for type and mode, transferred by
**descriptor** (`fchown`, never the pathname form), then re-checked for both
ownership and mode. Idempotent — a leaf already owned by the execution identity
is transferred to the identity it already has.

### 2.5 This widens a security backstop, and a reviewer must see it

The T11 backstop enumerates the privileged surface and forbids everything else.
It forbade `chown` and `chdir` outright. **`os.fchown` and `os.chdir` are now
permitted to this one module, and path-based `chown` stays forbidden** — the
object given away is the one already opened no-follow and verified, so there is
no pathname for a coordinator to swap between the check and the transfer.

This is the one change in this checkpoint that relaxes a guard rather than
tightening one. It is narrow, it is justified by §13, and it needs explicit
sign-off.

## 3. Root cause 2 — the reconciliation working directory

### 3.1 The chain

```
operator:  cd /opt/schott-platform && python3 -m tools.capability.cli execute …
           /opt/schott-platform is drwxr-x--- cschott:cschott (0750)

launcher.reconcile -> subprocess.run(RECONCILE_HELPER, …)      no cwd=  -> inherits
  privileged entrypoint (root — root can chdir anywhere, so this worked)
    drop_privilege -> becomes 999:987, cwd UNCHANGED and now unreachable
      reconcile worker -> PodmanBackend._execute -> subprocess.run(podman …)  no cwd=
        rootless podman re-execs into a user namespace, restores cwd, and fails
        -> "cannot chdir to /opt/schott-platform: Permission denied"
        -> surfaced by _execute as: the runtime refused: <detail>
```

The refusal text matches `_execute`'s own format exactly, which locates the site.

### 3.2 The source-level cause

`PodmanBackend._execute` is documented as:

> "One place where a process is created, and **every property of it is stated
> here rather than at a call site**."

It states `executable`, `shell`, `stdin`, `capture_output`, `env`, `timeout` and
`check`. **It did not state `cwd`** — the one property left inherited, in the
function whose contract is that nothing is.

And nothing else closed it either:

```
grep -rn "chdir|cwd" over the entire execution surface  ->  NOTHING
```

```
RECONCILE_CWD_ROOT_CAUSE  cwd is inherited across the privilege boundary while
                          identity is not, so a process that becomes the
                          execution identity can hold a cwd only the coordinator
                          can reach; no component anywhere closed it
EXPECTED_SAFE_CWD         "/"  — root:root 0755, traversable by every identity by
                          construction, holds no state this boundary touches,
                          compiled in with no parameter and no environment variable
CWD_SANITIZATION_BOUNDARY the credential drop (kyri_exec_transition_action.drop_privilege),
                          with the Podman subprocess boundary stating it as well
```

### 3.3 Why the drop, and not just the Podman call

A working directory becomes unreachable *because the identity changed*, so the
defect is at the identity change. `drop_privilege` is shared by the launch and
reconciliation transitions, so one fix closes both, and everything beyond
`execve` inherits a reachable cwd — including processes that never reach a
container runtime.

`_execute` states it **as well**, because that function's contract is that every
property is decided there. An invariant that holds only because something
upstream did it is not one that function can promise.

## 4. Same-class sweeps

### 4.1 Handoff children

Measured against the worker's own `EXPECTED_MODES` and open flags, on the live
handoff:

| child | mode / owner | consumer needs | class |
| --- | --- | --- | --- |
| handoff root | `0711` cschott | `O_PATH` anchor only | **TRAVERSE_ONLY** — SAFE (fixed at G11-BB) |
| `<CINV>/` | `0555` cschott | `O_RDONLY|O_DIRECTORY` | **READ_REQUIRED** — SAFE |
| `package/` | `0555` cschott | `O_RDONLY|O_DIRECTORY` | **READ_REQUIRED** — SAFE |
| `payload` | `0444` cschott | `O_RDONLY` | **READ_REQUIRED** — SAFE |
| `profile` | `0444` cschott | read by root before the drop; sealed into a memfd, then never read by name | SAFE |
| `out/` | `0700` **cschott** | `O_RDONLY|O_DIRECTORY` + rw bind as 999 | **LIVE_AND_WRONG** → fixed |
| snapshot root | worker-created after the drop | worker-owned by construction | SAFE |

```
HANDOFF_SAME_CLASS_LIVE_WRONG    1
HANDOFF_SAME_CLASS_LATENT_WRONG  0
```

### 4.2 cwd across every process-creation point

Every `subprocess.run`, `subprocess.Popen` and `execve` in the execution
surface, enumerated from the AST:

| site | runs as | class |
| --- | --- | --- |
| `kyri_exec_podman.py:275` `_execute` | execution identity | **LIVE_AND_WRONG** → `cwd` stated |
| `kyri_exec_podman.py:430` `start --attach` | execution identity | **LIVE_AND_WRONG** → `cwd` stated |
| `kyri_exec_podman.py:510` `inspect --type container` | execution identity | **LIVE_AND_WRONG** → `cwd` stated; this is the call that failed |
| `kyri_exec_transition_action.py` `execve` ×2 | inherits | SAFE — the drop now closes cwd before both |
| `kyri_exec_launcher.py:258` `Popen` (launch helper) | root, via sudo | **LATENT** — root can chdir anywhere, and the drop closes it downstream |
| `kyri_exec_launcher.py:278` `run` (reconcile helper) | root, via sudo | **LATENT** — same |

```
CWD_SAME_CLASS_LIVE_WRONG    3
CWD_SAME_CLASS_LATENT_WRONG  2
```

**I found three live sites, not one, because the test enumerates them.** I first
corrected only `_execute`; the podman suite counts required keywords across
*every* `subprocess.run` and refused the incomplete fix. The two `inspect` and
`start` sites are the ones reconciliation and launch actually use.

The two launcher sites are left unchanged deliberately: they run as root, where
the failure cannot occur, and the credential drop now closes cwd for everything
downstream. Widening the change to them would be defence in depth rather than a
correction, and is noted rather than done.

## 5. RED / GREEN

Both corrections were reverted one at a time against the finished suite:

```
WITHOUT the ownership transfer:
  FAIL  the accepted credential sequence runs in exactly the accepted order
  FAIL  descriptors are closed before any credential change
  FAIL  the output leaf is transferred to the execution identity
  FAIL  the transfer happens while privilege is still held
  FAIL  a refused transfer prevents the drop and the exec

WITHOUT the cwd closure:
  FAIL  the accepted credential sequence runs in exactly the accepted order
  FAIL  the credential drop closes cwd as well as credentials
  FAIL  cwd is closed before the identity changes, so no step runs unreachable

WITH BOTH:  Capability execution T11 transition-action validation passed.  (40 cases)
            Capability execution Podman backend validation passed.
```

The new assertions pin the sequence, not just the calls:

```
fchown -> close_extra_descriptors -> chdir -> setgroups -> setgid -> setuid
  -> credentials -> set_no_new_privs -> get_no_new_privs -> credentials -> execve
```

`fchown` precedes every credential step because only root can give a directory
away; `chdir` sits inside the drop, before the identity changes. A failure at
either prevents the drop and the exec.

### 5.1 The transfer is verified, not merely issued

An unprivileged fixture cannot hand the leaf to 999:987, and the production
post-transfer check refuses when the transfer does not take effect — which the
suite asserts. The same code path is then driven to completion with a policy
naming an identity the fixture *can* transfer to, so the refusal is proven to be
the verification working rather than the transfer being unimplemented.

## 6. The suite that proves all of this was silently skipping

`test-capability-execution-transition-action.sh` derived the coordinator uid with

```bash
sed -n 's/^COORDINATOR_UID = \([0-9]*\)$/\1/p' .../kyri-exec-transition.py
```

Commit `f9d94ce` removed that constant in favour of the deployment coordinator
identity authority. The `sed` matched nothing, `host_only_requires_identity ""`
compared an empty string against the real uid, and **every run since reported
`HOST_ONLY_SKIP` — including on the production host**, where this is the suite
that proves the privileged credential sequence.

A skip produced by a stale extraction is worse than a failure: it reads as "not
applicable here" rather than "nobody checked".

Un-skipping it surfaced **37 failures of accumulated bit-rot**, every one
pre-existing:

| stale thing | reality |
| --- | --- |
| `policy_for()` called without `identity=` | the parameter became required and has no default |
| fixture built its own identity record | the policy requires a root-owned authority; the real one is read now, with only the resolver injected |
| `/etc/kyri` not in the fixture's roots | the coordinator authority lives there and is read on every transition |
| recorder opened roots `O_RDONLY` | production uses `O_PATH`; two governed roots are `0711`, so `O_RDONLY` refuses — the exact G11-BB defect, reproduced in the fixture |
| backstop forbade `pwd`/`grp` | the account resolver deliberately lives in the action layer, by the policy module's own argument |
| backstop forbade `os.O_PATH` | added by the G11-BB anchor correction |
| "never mentions Podman" read the RAW file | it failed on the module's own sentence *"Podman is not reachable from here"* — prose asserting the property under test. It now strips docstrings the way the real backstop does, so it tests **coupling, not commentary** |

None of these were weakened to pass. Each was corrected to test what it claims.

## 7. Recovery safety — CINV-000002 is discoverable

Read-only against the real store with the installed Generation-16 runtime. **No
governed recovery was run and no reconciler was invoked against production.**

```
lifecycle journal        {'CINV-000001': 'launch_authorized', 'CINV-000002': 'launch_authorized'}
DISCOVERED CINV-000001   identity=CINV-000001  adapter=None  lifecycle=launch_authorized
DISCOVERED CINV-000002   identity=CINV-000002  adapter=None  lifecycle=launch_authorized

CINV-000002 discoverable : True
by record id, not opaque : True
adapter_identity needed  : False
```

### 7.1 Why `launch_authorized` is the right state to discover from

The brief asks how recovery finds a *failed* execution when the persisted
lifecycle still reads `launch_authorized`. It is not a gap — it is the design:

```
_CONTAINER_POSSIBLE_FROM  = launch_authorized
CINV-000002 state         = launch_authorized
_container_possible(state)= True
```

**The durable evidence that marks container possibility is the lifecycle
transition journal entry written by `authorise_launch` before the privileged
boundary is crossed**, not anything written after a failure. That is precisely
why "a refusal writes nothing" is safe: the journal already records that
execution was authorised, so an invocation at or beyond `launch_authorized` with
no terminal result is exactly the set recovery enumerates.

```
RECOVERY_DISCOVERS_CINV_000002 = YES
```

## 8. Deployment class

```
DEPLOYMENT_REQUIRED  YES
DEPLOYMENT_CLASS     BOTH — a helper ceremony AND a Generation-17 runtime ceremony
```

| object | installed | corrected | governed by |
| --- | --- | --- | --- |
| `kyri_exec_transition_action.py` | `b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315` | `2bd86f3d7ad99375aa1d725c5309343df1d99317cac092ccc8849493b03a6d78` | **helper ceremony** (G11-AX, then G11-BB) |
| `kyri_exec_podman.py` | `cf26b29810e4298000803f36481c4439d116b380df316262c2f8696b5e24ebe8` | `04205c53ec0e10bef13099dd3a84c483e43ed9441335805665f957a5bbdd896b` | **Generation 13** — a runtime generation object |
| `tools/capability/execution/helpers.py` | `6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07` | must declare the new action digest | **runtime generation** |

```
RUNTIME_DELTA  kyri_exec_podman.py, tools/capability/execution/helpers.py
HELPER_DELTA   kyri_exec_transition_action.py
```

### 8.1 Sudoers does not change

The two grants pin the **entrypoints**, and neither moves:

```
kyri-exec-transition-entrypoint.py  0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1  == installed
kyri-exec-reconcile-entrypoint.py   2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77  == installed
```

```
SUDOERS_CHANGE_REQUIRED = NO
```

The changed objects are modules the entrypoints load, not the entrypoints
themselves. The verification grant stays absent.

### 8.2 Helper compatibility declaration changes, and that is why validation is red

`kyri_exec_transition_action.py` is in `helpers.REQUIRED_HELPERS` by digest. The
supervision suite refuses:

```
FAIL: the runtime declares the helper bytes it supervises through
  ('/usr/lib/kyri/python/kyri_exec_transition_action.py',
   'provisioning/execution/kyri-exec-transition-action.py',
   'the declaration is stale')
```

**That refusal is the deployment rule working, and it is the same shape as
G11-BC-A.** `helpers.py` is deliberately left declaring the installed digests, so
the repository stays consistent with the host. Moving it is the Generation-17
ceremony's job, and building that ceremony is the next checkpoint's work rather
than something to fold into a root-cause checkpoint.

I did not suppress, skip, or relax this check to make the branch green.

### 8.3 Advancing the declaration is not a shortcut either — probed

To confirm that the supervision refusal is the *only* red, `helpers.py` was
temporarily advanced to declare the new action digest and full validation was
re-run. It did not go green; it refused **earlier**, at the G5 preflight:

```
FAIL  the declared object tools/capability/execution/helpers.py is 10f26c72…,
      which is not a declared successor (74b84015…,6dd93606…)
Validation stopped at step 59.
```

So the two governed declarations close on each other: `helpers.py` may not
declare new helper bytes until a **generation** declares `helpers.py`'s own new
bytes — the same rule that produced G11-BC-A's deliberate red for `recovery.py`.
The probe was reverted; `helpers.py` is byte-identical to the installed object
(`6dd93606…`) and the working tree is clean.

**This is why the deployment class is BOTH and not either.** It also sharpens
which mechanism governs which object: the preflight's drift loop walks
`tools/**` only, which is why changing `kyri_exec_podman.py` and
`kyri_exec_transition_action.py` does not trip it — those are flattened
library-root modules governed by their ceremonies' own matrices — while
`helpers.py`, being under `tools/`, needs a Generation-17 `GENERATION_DELTA`
successor row as well as a ceremony matrix row.

## 9. CINV-000002 resumability

Proven from the installed source, not inferred.

```
command_execute lifecycle guard : NONE — it reads the record and the published
                                  launch authorisation, and consults no state machine
authorise_launch at LAUNCH_AUTHORIZED : accepted, `resumed = True`
result collision on retry       : record_terminal_result refuses a second
                                  attempt_number == 1 — and no result exists
```

```
CINV_000002_FINAL_CLASSIFICATION  UNRESOLVED — launch_authorized, no terminal result,
                                  no container, recoverable and retryable
CINV_000002_RESUME_POSSIBLE       YES, after the corrections are deployed
CINV_000002_RESUME_AUTHORISED     NO
```

**No new CINV is required, and `recover` is not required first.** The refusal
happened before any container existed (`worker_reaped: true`, no
`kyri-CINV-*` container), so there is no orphan for recovery to dispose of.
Running `recover` would still be a reasonable pre-retry check, and it is now
capable of finding this invocation (§7) — but it is a privileged action with its
own authorisation and is not authorised here.

The safe order, for a later checkpoint to authorise: deploy both corrections →
confirm no `kyri-CINV-*` container → retry `execute`.

## 10. Validation

```
FOCUSED
  transition-action  PASS  (40 cases, first real run on this host)
  podman-backend     PASS
  handoff            PASS   worker-binding  PASS
  recovery-discovery PASS   supervision     FAIL — §8.2, by design
  reconciliation     PASS
  shellcheck         clean

LOCAL_FULL   RED at step 105, the supervision suite, for the reason in §8.2
LOCAL_QUICK  RED at the same suite

GITHUB_CI    5/6 — ShellCheck, Semgrep, CodeQL, Trivy, Gitleaks all green
             CI: FAILURE, at exactly one assertion:
               FAIL: the runtime declares the helper bytes it supervises through
               Capability execution supervision validation FAILED: 1
CLEAN_CLONE  not run — it would reproduce the same declared refusal, which is a
             property of the declaration rather than of the checkout
```

**The same single assertion fails locally and in CI, and nothing else does.**
That suite is not host-only, so CI exercises it in full — the red is the
deployment rule, not a portability artefact.

**Local validation is RED and this checkpoint does not claim otherwise.** The one
failing assertion is the runtime refusing to declare helper bytes it was not
built against, which is exactly the property that makes a split helper surface
impossible. It goes green when Generation 17 declares `2bd86f3d…`.

## 11. Production non-mutation

```
CINV-000002   923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   UNCHANGED
CINV-000001   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CRES_COUNT 0        invocation sequence 2        no new invocation identity
lifecycle     CINV-000002 launch_authorized, two journal records, unchanged
handoff       payload e2914a90…  profile b707d433…  package/main.py 683e25ed…
              modes unchanged — NOT touched by any diagnostic
Fabric 3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b  unchanged
Trust  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f  unchanged
sudoers       two grants, verify grant absent, unchanged
installed runtime and helpers   unchanged — nothing was deployed
```

```
NO EXECUTE. NO RECOVER. NO RECONCILER AGAINST PRODUCTION. NO CONTAINER
MANIPULATION. NO CRES. NO LIFECYCLE WRITE. NO HANDOFF PERMISSION CHANGE.
NO FABRIC, TRUST OR SUDOERS MUTATION. NO DEPLOYMENT.
```

The read-only diagnostics opened descriptors and stat'd objects; the fixtures
that exercised the corrections ran in temporary trees and were removed.

## 12. STOP — next checkpoint

```
STAGE3_AUTHORISED  NO      PRODUCTION_INVOKE_AUTHORISED  NO
CINV_000002_RESUME_AUTHORISED  NO
```

The next checkpoint is **Generation-17 and helper-ceremony preparation** for
these two corrections, which must:

1. carry `kyri_exec_transition_action.py` `b11a2f19…` → `2bd86f3d…` as a helper
   ceremony, with `helpers.py` declaring the successor digest;
2. carry `kyri_exec_podman.py` `cf26b298…` → `04205c53…` and the new `helpers.py`
   as a Generation-17 runtime ceremony;
3. respect the cross-surface ordering the G11-BB helper ceremony established —
   the runtime declaration and the helper bytes must not be split;
4. change no sudoers grant and no entrypoint.

**Before that ceremony is authorised, a reviewer must explicitly accept the
backstop widening in §2.5** — `os.fchown` and `os.chdir` permitted to the
privileged action layer — because it is the one guard this checkpoint relaxes.
