# ENG-0005 G11-BB-D — Stage 3 unresolved, root cause

**Status: diagnostic only. Production was not mutated.** No `execute` retry, no
`recover`, no `chmod`/`chown`, no Podman command, no `CRES`, no `CINV` change.
`CINV-000001` is byte-identical to its Stage-1 baseline.

Follows **[G11-BB-C](2026-09-04-g11-bb-c-stage-2-launch-authorisation-acceptance.md)**.

Branch `arch/eng-0005-execution-transition`, HEAD `af1a51c`.

---

## 1. Verdict

**The handoff root's `0711` is correct and governed. The worker is wrong.**

`/usr/libexec/kyri-exec-worker.py:378` opens the handoff *parent* with
`O_RDONLY|O_DIRECTORY`, asking for **read** on a directory the design
deliberately grants only **traverse**. The mode must not be widened; the open
must be corrected.

The reconciliation message is a **second, separate** matter and is **not yet
root-caused** — §4. It is a masking defect: the real refusal went to `stderr`
and the launcher discards it.

## 2. Handoff authority, traced

### 2.1 Where `HANDOFF_ROOT` is defined

Four independent definitions, all agreeing on `/data/kyri/capability-handoff`,
each on its own side of a boundary so no side reads another's constant:

```
tools/capability/execution/launch.py:67        coordinator (publisher)
tools/capability/execution/worker.py:59        runtime library
provisioning/execution/kyri-exec-transition.py:64   privileged transition
provisioning/execution/kyri-exec-quota.py:40        quota helper
provisioning/execution/kyri-exec-verify-worker.py:74  verification entrypoint
```

### 2.2 The governed owner and mode — explicit, in three places

**`docs/superpowers/specs/2026-08-11-first-adapter-design.md` §13:**

| Path | Owner | Mode | `kyri-capability` | Purpose |
|---|---|---|---|---|
| `/data/kyri/capability-handoff/` | `cschott:cschott` | `0711` | **traverse only** | handoff parent — traverse to a named child, no enumeration |
| `…/<CINV>/` | `cschott:cschott` | `0555` | read+traverse | per-invocation handoff |

> *"`0711` on the handoff parent is deliberate: the worker must traverse to a
> named child because rootless Podman resolves bind-mount sources **as the
> execution identity**, and must not enumerate siblings."*

**`docs/superpowers/specs/2026-08-11-execution-transition-boundary.md` §8.1:**

> *"`/data/kyri/capability-handoff/<CINV>/` — coordinator-owned, mode `0711` on
> the parent so the execution identity can traverse to a named child without
> enumerating siblings; `0555` on the invocation directory; artefact `0444`."*

**`provisioning/execution/README.md`:**

> *"Create with these owners and modes exactly; **none of them inherits a mode
> by convention**."* — followed by the same `0711` row.

**So `0711` is governed, not inherited deployment state.** Live production
matches the authority exactly: `cschott:cschott 0711` on the parent,
`cschott:cschott 0555` on `CINV-000001`, `0444` on `payload`/`profile`,
`0555` on `package/`, `0700` on `out/`.

`HANDOFF_ROOT_MODE = 0711` — **correct**. `HANDOFF_ROOT_OWNER = cschott:cschott`
— **correct**.

### 2.3 Which ceremony created it

The directory is a **deployment storage authority** item from design §13,
provisioned per `provisioning/execution/README.md`, not created at runtime.
Nothing in `tools/` or `provisioning/` creates it — every reference opens it.
It predates this checkpoint and was present and empty at
[G11-W](2026-08-28-g11-w-pre-invoke-operation-authority-audit.md).

### 2.4 What the publisher assumes about the reader

`launch.publish_handoff` writes as the coordinator and then re-verifies. It
assumes the reader reaches `<CINV>` **by name**, which is why the parent is
traverse-only and the child is `0555`. The publisher never assumes the reader
can list the parent.

### 2.5 Why the worker opens the root at all

Because it needs a `dir_fd` to anchor descriptor-relative resolution — the same
discipline used everywhere else in this boundary. **It never enumerates it.**
Every use of the descriptor is `openat`:

```
tools/capability/execution/worker.py:385    os.open(validated, _DIR_FLAGS, dir_fd=root_fd)     verify_handoff
tools/capability/execution/worker.py:603    os.open(profile.cinv, _DIR_FLAGS, dir_fd=root_fd)  verify_execution
tools/capability/execution/snapshot.py:352  os.open(cinv, _DIR_FLAGS, dir_fd=handoff_fd)       materialise
```

`snapshot.py` does call `os.scandir`, at lines 245, 304 and 463 — **checked, and
none of them is the handoff root**: they walk the *package* subtree
(`source_fd`, a `0555` directory) and the *snapshot* directory. The handoff root
is only ever a `dir_fd`.

**`openat` requires only search permission on the anchoring directory**, which
`0711` grants. The requirement the worker actually has is satisfiable under the
governed mode; the flags it uses ask for more than it needs.

### 2.6 The defect is in reviewed source, not deployment drift

```
6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd  /usr/libexec/kyri-exec-worker.py
6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd  provisioning/execution/kyri-exec-worker.py
```

Byte-identical. The installed worker is the reviewed worker, and helper
compatibility reports `compatible` because the digest is exactly what
`REQUIRED_HELPERS` declares. **The compatibility check is working; the bytes it
vouches for carry the defect.**

### 2.7 The working reference pattern

The same file already demonstrates the correct discipline elsewhere: every
nested object is reached with `openat` from the descriptor its parent was opened
as, never by pathname. The parent-anchor open is the one place that asks for
read instead of traverse. `O_PATH` is the flag for "I want this only as an
anchor" — it is precisely the descriptor the governed mode is shaped for.

## 3. Reproduction, RED-first

`tests/test-capability-execution-handoff-root-traversal.sh` — unprivileged,
isolated, no sudo, no Podman, no production path.

It builds the production shape mode for mode — parent traverse-only, `<CINV>`
`0555`, `package/` `0555`, `payload`/`profile` `0444`, `out/` `0700` — and
copies `_DIR_FLAGS` verbatim from the worker entrypoint.

```
ok    the fixture parent is traverse-only (0111)
ok    O_RDONLY|O_DIRECTORY on a traverse-only parent is refused      <- production failure
ok    O_PATH open of a traverse-only parent succeeds
ok    openat(root_fd, CINV) reaches the child
ok    the child is readable, as 0555 intends
ok    the parent still cannot be enumerated                          <- property a lax fix destroys
```

**Ownership differs from production by necessity** — this suite may not become
uid 999. The permission *semantics* are identical: the fixture removes read from
the owner (`0111`) exactly as `0711` removes it from `kyri-capability`, which
reaches the directory as "other". The failing call, the flags and the directory
shape are the production ones.

**The last assertion is the one that matters for the fix.** Widening the parent
to `0755`/`0750`, adding a group, or granting an ACL would satisfy the first
assertion and silently destroy the no-enumeration property the design names.
An `O_PATH` descriptor cannot be read at all, so the property holds by
construction rather than by permission.

## 4. Reconciliation — a separate, still-unidentified refusal

### 4.1 The mechanism, traced

```
supervisor → HelperLauncher.reconcile(cinv)                 kyri_exec_launcher.py:233
  subprocess.run(["/usr/bin/sudo", "/usr/libexec/kyri-exec-reconcile", "CINV-000001"],
                 stdin=DEVNULL, capture_output=True, timeout=…, env=closed)
  → /usr/libexec/kyri-exec-reconcile          runs as root via the installed grant
      validates argv, reads /etc/kyri/execution-identity.json,
      closes descriptors, DROPS CREDENTIALS to 999:987, no_new_privs, execs:
  → /usr/libexec/kyri-exec-reconcile-worker.py    refuses to run as root (uid/gid 0)
      requires (uid, gid) == (999, 987)
      backend = runtime.backend_for(ADAPTER_IDENTITY, environment=…)
      report  = reconciler.reconcile(cinv, backend=backend)
      sys.stdout.write(json.dumps(report) + "\n")            ← the ONLY stdout write
  ← launcher: json.loads(done.stdout)
      on failure → LauncherRefused("the reconciliation helper produced no readable report")
```

**It does not depend on `HANDOFF_ROOT`.** Confirmed by search: no reference to
the handoff root anywhere in `kyri_exec_reconcile.py` or the reconcile
entrypoint. `RECONCILIATION_SAME_DEFECT = NO`.

### 4.2 Absent-container behaviour is idempotent, as specified

`kyri_exec_reconcile.reconcile()` — *"Idempotent by construction: the absent
case is a success"*:

```python
document = backend.find_container(name)
if document is None:
    report.update({"outcome": "absent", "prior_state": None,
                   "final_absent": True, "container_identity_verified": True})
    return report
```

**So had `reconcile()` been reached, an absent container would have produced a
readable report with `final_absent: true`** — and the supervisor would have
proven disposal. It returns a report; it does not raise.

### 4.3 Therefore the failure happened *before* `reconcile()` returned

Every earlier failure path in the reconcile worker raises
`SystemExit(f"refused: {…}")`, which writes to **stderr** and leaves **stdout
empty**. `json.loads(b"")` then raises, and the launcher reports *"produced no
readable report"*.

**The launcher captures `done.stderr` and never surfaces it.** The actual
refusal reason exists and was discarded. That is a diagnosability defect in
`HelperLauncher.reconcile`, and it is why this cannot be root-caused from the
evidence in hand.

### 4.4 Leading hypothesis, not yet evidence

The installed sudoers `Defaults` include **`use_pty`** (BA §11.3). With
`use_pty`, sudo runs the command under a pseudo-terminal; a pty has **one**
stream, so the child's stderr can land on the parent's stdout. Any stderr
output — a warning, a refusal line — would then corrupt the JSON and produce
exactly this message **even for a reconciliation that succeeded**.

That is a hypothesis with a specific test, not a conclusion. Two candidate
classes remain open:

1. `use_pty` merging streams and corrupting an otherwise-valid report;
2. a genuine refusal before `reconcile()` — identity mismatch, module load, or
   `runtime.backend_for` failing to construct the Podman backend.

### 4.5 The evidence needed

Read-only, and it is the governed reconcile path itself — idempotent, and
absence counts as success:

```bash
sudo /usr/libexec/kyri-exec-reconcile CINV-000001 \
  > /tmp/reconcile.out 2> /tmp/reconcile.err ; echo "rc=$?"
echo "--- stdout ---"; cat -A /tmp/reconcile.out | head -20
echo "--- stderr ---"; cat    /tmp/reconcile.err | head -20
```

`cat -A` matters: it shows whether `\r` appears, which distinguishes hypothesis
1 from hypothesis 2. **This needs reviewer authorisation** — it invokes a
privileged helper, which is outside the current standing permission. It creates
no container and writes no governed record.

## 5. Post-failure governed state, verified live

```
CINV-000001          1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CINV_COUNT           1
CRES_COUNT           0
capability-invocation.seq   1
capability-result.seq       ABSENT
transitions          CINV-000001.000001 (reserved), CINV-000001.000002 (launch_authorized)
                     — no later transition exists
handoff out/         0 entries — the worker never wrote
```

Authority planes, all unchanged:

```
fabric   7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
sudoers  f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
```

Operator-observed as `kyri-capability`: only historical `trackb-*` containers;
**no `kyri-CINV-000001`**. `CONTAINER_CREATED = NO`.

**`disposal_proven` stays `false`.** The governed supervisor could not establish
it, and an operator observation is not a substitute for the proof the supervisor
owes. Recorded as reported, not overridden.

## 6. Recovery classification

### 6.1 A finding that changes what `recover` would do

`recovery.unresolved_invocations` skips any invocation with no
`adapter_identity`:

```python
adapter_identity = record.get("adapter_identity")
if not adapter_identity:
    continue
```

> *"An invocation with no `adapter_identity` is not unresolved — nothing was
> ever authorised to run, so there is no container it could have left."*

**`CINV-000001` carries `adapter_identity: null`** (BB-B §1), because
`command_invoke` supplies neither adapter nor execution binding and
`_bound_adapter_identity` therefore yields `None`. **Nothing later writes it** —
`record_terminal_result` *"never touches the invocation record"*.

So `recover` would enumerate **zero** invocations and report
`execution_safety: ready`. For this incident that verdict is materially
right — no container was created — but it is right by luck, not by evidence:
`recover` would say the same thing if a container *had* been left behind.

**This is a genuine architectural gap and it is recorded, not acted on.** In the
supervised three-stage flow the CINV's `adapter_identity` is always null, so an
invocation that reached `launch_authorized` and lost supervision after creating
a container would be invisible to the one surface built to find it. It needs its
own checkpoint.

### 6.2 Is `CINV-000001` resumable?

The state machine says yes; the standing ruling says no; the two are not in
conflict, because the second is a policy the first does not encode.

**What source shows:**

- lifecycle is still `launch_authorized`, and the privileged transition requires
  exactly that (`kyri_exec_transition.py:746`
  `_require(state == LAUNCH_AUTHORIZED)`). A second `execute` would satisfy that
  gate.
- `authorise_launch` has an explicit resume path (`current is LAUNCH_AUTHORIZED
  → resumed = True`), so **Stage 2 is deliberately idempotent**.
- `capacity.reserve` refuses a `CINV` that *"already has durable execution
  state"* — so a re-run must not re-reserve, and `execute` does not call it.
- `execute` allocates no identity and consumes no sequence.

**What source does not show:** any explicit, named resume mechanism for Stage 3.
`recover` deliberately *"writes nothing"* and resolves the container question
only; it is not a resume.

**Therefore `CINV_RESUMABILITY = UNRESOLVED`** — a reviewer decision, not an
inference. The architecture permits a second `execute` and does not bless one.
The standing BB prohibition remains in force and this report does not seek to
lift it. `CINV-000001` stays unresolved and untouched; `CINV-000002` is not
spent.

## 7. Correction plan — not applied

`CORRECTION_CLASS = multiple`.

**No deployment storage-authority change.** `0711 cschott:cschott` is correct
(§2.2) and must not be touched. This is the most important line in the plan.

| # | change | class | why |
| --- | --- | --- | --- |
| 1 | `provisioning/execution/kyri-exec-worker.py:378` — open the handoff root `O_PATH\|O_CLOEXEC\|O_NOFOLLOW\|O_DIRECTORY` instead of `_DIR_FLAGS` | **helper ceremony** | the file is one of the eight objects in `REQUIRED_HELPERS`; its digest changes |
| 2 | `tools/capability/execution/helpers.py` — update the declared digest for `/usr/libexec/kyri-exec-worker.py` | **runtime generation** | the declaration must move with the bytes or compatibility reports a stale helper |
| 3 | *(pending §4)* reconciliation defect | **TBD** | classification blocked on the §4.5 evidence |

**Sudoers: unchanged.** The worker is not sudo-invoked; the pinned entrypoints
are `kyri-exec-transition` and `kyri-exec-reconcile`, whose digests do not move.
`/etc/sudoers.d/kyri-exec-verify` stays absent.

Note the ordering constraint: changes 1 and 2 must land together. Installing a
new worker without updating `helpers.py` makes `compatibility()` report `stale`
and blocks supervision — correctly, which is the check doing its job.

**Also required before this is complete:** a reconciliation absent-container
test, once §4 is classified. `tests/test-capability-execution-handoff-root-traversal.sh`
covers the primary defect and is committed with this report.

The deferred verification-surface remediation (BA §0.1) is **still deferred** and
is not folded into this correction.

## 8. Window

```
host now                     2026-09-04T20:44:49-05:00
CADV-000004.valid_until      2026-09-06T12:02:14-05:00   inside: True
CINST-000003.admitted_until  2026-09-06T12:02:14-05:00   inside: True
WINDOW_REMAINING             39h 17m   (141444 s)        expired: False
```

Nothing renewed. Adequate for a correction ceremony, but the correction touches
a helper and a runtime generation, so the window should be watched rather than
assumed.

## 9. Standing

```
BB_STAGE3                          UNRESOLVED
HANDOFF_ROOT_OPEN_FAILURE          CONFIRMED — worker defect, not deployment
HANDOFF_ROOT_MODE                  0711        correct and governed
HANDOFF_ROOT_OWNER                 cschott:cschott   correct and governed
CONTAINER_CREATED                  NO
WORKER_REAPED                      YES
DISPOSAL_PROVEN                    NO
RECONCILIATION_REPORT_FAILURE      stdout empty or corrupted; real reason on discarded stderr
RECONCILIATION_SAME_DEFECT         NO
CINV_RESUMABILITY                  UNRESOLVED — reviewer decision
EXECUTE_RETRY_AUTHORISED           NO
RECOVER_AUTHORISED                 NO
CORRECTION_CLASS                   multiple (helper ceremony + runtime generation)
PRODUCTION_MUTATION_FROM_DIAGNOSTICS   NONE
```

## 10. Next

1. **Reviewer rules on the correction plan** (§7) and on `CINV-000001`
   resumability (§6.2).
2. **Reviewer authorises the §4.5 read-only reconcile evidence** so the second
   defect can be classified. Until then its correction class is unknown.
3. Implement changes 1 and 2 together, RED-first, with the committed test
   extended to cover the corrected entrypoint.
4. Separately: the `adapter_identity` recovery gap (§6.1) needs its own
   checkpoint — it is not this correction's to fix.
