# ENG-0005 G11-BB-F — the second anchor defect, and the sweep

**Status: implemented in the repository, not deployed. Production untouched.**
No mode, owner or ACL changed anywhere. `CINV-000001` byte-identical,
`CINV-000002` unspent.

Follows **[G11-BB-E](2026-09-04-g11-bb-e-corrections-b-and-d.md)** and the
authorised reconcile diagnostic.

Branch `arch/eng-0005-execution-transition`, HEAD `b74f2fb`.

---

## 1. Root cause — Task A

The diagnostic settled it:

```
rc=1
stdout: EMPTY
stderr: refused: the execution authority directory is unusable:
        [Errno 13] Permission denied: '/etc/kyri'
```

`USE_PTY_HYPOTHESIS = REFUTED`. Stdout was empty because the helper genuinely
refused before reaching `reconcile()`, exactly as BB-D §4.3 predicted, and said
why on stderr — which the launcher discarded.

### 1.1 The open

```
provisioning/execution/kyri-exec-transition-action.py:248
  _read_authority()  →  root = backend.open_directory("/etc/kyri")
  SystemBackend.open_directory  →  os.open(path, _DIR_FLAGS)
  _DIR_FLAGS = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY
```

The descriptor is used **only** as an `openat` anchor:
`os.open(name, _READ_FLAGS, dir_fd=root)`. `_open_invocation` fstats the
**child**, never the root, and **neither privileged module calls `listdir` or
`scandir`** — verified by search.

### 1.2 The governed authority

```
/etc/kyri                            root:root  0711   traverse-only
/etc/kyri/execution-identity.json    root:root  0444   world-readable
/etc/kyri/coordinator-identity.json  root:root  0444   world-readable
```

**The files are readable; the directory is not listable.** That is the intended
shape, and it is the same shape as the handoff root: reach a named child, do not
enumerate siblings. `identity.py` documents why the sibling set matters — *"a
name that cannot appear in a sudoers grant must not be readable as authority
either"* — and a non-enumerable authority directory keeps the set of deployment
authorities from being discoverable by anything that merely holds traverse.

`EXECUTION_AUTHORITY_MODE = 0711`. `EXECUTION_AUTHORITY_OWNER = root:root`.
**Correct, and not widened.**

### 1.3 The same authority is read two ways, and only one was wrong

| reader | how | needs | outcome |
| --- | --- | --- | --- |
| `tools/capability/execution/identity.py:250` | `os.open(EXECUTION_AUTHORITY_PATH, O_RDONLY\|O_NOFOLLOW\|O_CLOEXEC)` — the **file**, by path | traverse only | **works** |
| `kyri-exec-transition-action.py:248` | `open_directory` then `openat` — the **directory** first | asked for read | **refused** |

That is why the worker reads the identity happily after the drop while the
reconcile worker could not. The privileged reader anchors first so no component
can be swapped between check and read — the anchoring is right; asking for read
was not.

`RECONCILIATION_SAME_DEFECT_CLASS_AS_HANDOFF = YES.`

### 1.4 Why it appeared only in reconciliation

`execution_identity()` is called on three paths. Two run **as root before**
`drop_privilege` and root bypasses the check. The third — the reconcile worker
at `kyri-exec-reconcile-worker.py:110` — runs **after** the drop as `999:987`.

The launch path got past its own copy for the same reason, which is why Stage 3
reached the worker at all.

## 2. Correction — one seam, three anchors

`SystemBackend.open_directory` now opens `O_PATH`. It is the only filesystem
seam in the privileged backend, and all three callers use the descriptor solely
as `dir_fd`:

```
248  /etc/kyri                            deployment authority read
387  EXECUTION_ROOT                       launch record read
422  HANDOFF_ROOT                         profile source read
```

**`O_PATH` is what an anchor is for.** `openat` needs search, which `0711`
grants; and an `O_PATH` descriptor cannot be read at all, so "no sibling
enumeration" stops depending on the mode and becomes a property of the
descriptor.

`kyri-exec-quota.py` carries the identical anchor and is corrected too. It was
**latent, not broken** — `quota.apply()` runs above `drop_privilege`, as root —
but the descriptor's use is identical and a latent instance of a defect that has
already cost two checkpoints should not wait for the ordering to change. Its
`CINV` child keeps `_DIR_FLAGS`: that directory is `0555`, it grants read, and
it is read.

## 3. Defect-class sweep — Task B

Classified by **which identity opens which directory**, since the defect only
bites where a non-owner meets a traverse-only directory. The two such
directories in production are `/etc/kyri` and `/data/kyri/capability-handoff`.

| site | root | acting identity | verdict |
| --- | --- | --- | --- |
| `kyri-exec-worker.py:378` | handoff root | worker, post-drop | **LIVE_AND_WRONG** — fixed (BB-E) |
| `transition-action.py:248` via reconcile worker | `/etc/kyri` | worker, post-drop | **LIVE_AND_WRONG** — fixed here |
| `transition-action.py:248` via transition | `/etc/kyri` | root, pre-drop | **LATENT_AND_WRONG** — fixed here |
| `transition-action.py:387` | execution root `0700` | root, pre-drop | **LATENT_AND_WRONG** — fixed here |
| `transition-action.py:422` | handoff root `0711` | root, pre-drop | **LATENT_AND_WRONG** — fixed here |
| `kyri-exec-quota.py:151` | handoff root `0711` | root, pre-drop | **LATENT_AND_WRONG** — fixed here |
| `kyri-exec-verify-worker.py:164` | handoff root `0711` | verify worker, post-drop | **LATENT_AND_WRONG** — deferred, see below |
| `identity.py:250` execution identity reader | opens the **file** | worker, post-drop | **SAFE** — no directory open |
| `cli.py:324` coordinator identity reader | opens the **file** | coordinator | **SAFE** |
| `cli.py` `_anchored` roots | runtime store, handoff | coordinator, **owner** | **SAFE** — owner holds `rwx` under `0711`/`0700` |
| `snapshot.py`, `worker.py` `openat` sites | handoff `<CINV>` `0555` | worker | **READ_ACTUALLY_REQUIRED** — the child is enumerated and copied |
| `trusted_source.py` payload root | operator-owned `0700` | coordinator, owner | **SAFE** |
| `state.py`, `mutation.py`, `capacity.py`, `admin.py`, `quarantine.py`, `cleanup.py`, `handoff.py` | runtime store `0700` | coordinator, owner | **SAFE** — several genuinely enumerate |
| `image_store.py` graphroot | worker's own `HOME` | worker, owner | **SAFE** |
| `implementation_authority.py` | `/var/lib/kyri/implementation-authority` | coordinator | **SAFE** |

**No blanket replacement.** Flags were converted at exactly the sites where
source proves the descriptor is an anchor and nothing enumerates it. Everywhere
a directory is genuinely listed — the package copy walk, the snapshot cleanup,
the state journal scan — `_DIR_FLAGS` is untouched and correct.

`kyri-exec-verify-worker.py` is the one known remaining instance. It belongs to
the deferred verification-surface remediation (BA §0.1), whose entrypoint is
unauthorised and ungranted, and folding it in would enlarge this ceremony into
scope the reviewer explicitly deferred. **Recorded, not fixed.**

## 4. Launcher diagnosability — Task C

The launcher captured `done.stderr` and reported only *"produced no readable
report"*, naming the symptom and discarding the cause. A checkpoint was spent
recovering a message that had already been produced and thrown away.

```python
MAXIMUM_REFUSAL_EXCERPT = 300

def _excerpt(stream):
    """One bounded, printable, single-line excerpt of a helper's own refusal."""
```

Decoded lossily, reduced to printable ASCII, collapsed to one line, truncated.
**Never parsed and never trusted as structure** — it informs an operator; it is
not state anything acts on. The refusal still refuses; only its message grew.

That bound matters: an unstructured stream may be empty, enormous, binary, or
full of terminal control sequences, and any of those reaching a log or a report
would be its own defect.

## 5. Tests

**`tests/test-capability-execution-authority-anchor.sh`** — 20 assertions, all
passing, unprivileged and isolated:

```
ok  O_RDONLY|O_DIRECTORY on the authority directory is refused   <- the failure
ok  O_PATH anchor of the authority directory succeeds
ok  openat reaches execution-identity.json through the anchor
ok  the authority directory still cannot be enumerated
ok  a sibling is reachable by name but was never listed
ok  the privileged backend declares an O_PATH anchor
ok  SystemBackend.open_directory succeeds on a traverse-only root
ok  a real refusal survives into the excerpt
ok  control characters are stripped
ok  an enormous stderr is bounded
ok  the launcher still refuses an unreadable report
ok  and its refusal now names the cause
```

The sibling assertions are the point: reachable **by name**, never **listed**.
That is traverse, and it is what a widened mode would have destroyed.

**30 of 32** affected suites pass. The two failures are **pre-existing and not
regressions** — both fail identically at `3636976`, before any code change in
this correction:

- **`launch-cli`** asserts `os.listdir('/data/kyri/capability-handoff') == []`.
  It now holds `CINV-000001`, published by the real G11-BB ceremony. The suite
  encodes "production has never been invoked" as an invariant, and that
  invariant is now permanently false.
- **`g5-preflight`** compares the checkout against a generation declaration that
  was **already stale before this work** — 18 failures at `3636976`, 24 now. The
  6 additional are this correction's runtime objects reported as *"ahead of the
  installed generation by declaration"*, which is the correct description of
  undeployed work.

Both belong to deployment preparation (item G), not to this correction. Fixing
either now would mean editing a suite to match production rather than the other
way round, which is the wrong direction to move evidence in.

## 6. Correction scope — Task D

| # | change | object | class |
| --- | --- | --- | --- |
| 1 | worker handoff anchor | `kyri-exec-worker.py` | **helper** |
| 2 | quota anchor | `kyri-exec-quota.py` | **helper** |
| 3 | backend anchor seam | `kyri-exec-transition-action.py` | **helper** |
| 4 | declared digests | `tools/capability/execution/helpers.py` | runtime |
| 5 | recovery discovery | `tools/capability/execution/recovery.py` | runtime |
| 6 | recovery root threading | `tools/capability/cli.py` | runtime |
| 7 | launcher diagnostics | `kyri-exec-launcher.py` | runtime |

```
CORRECTION_CLASS          multiple (helper ceremony + runtime generation)
HELPER_CEREMONY_REQUIRED  YES — three objects
NEXT_GENERATION           15  — four runtime library objects
SUDOERS_CHANGE            NONE — no pinned entrypoint digest moves
DEPLOYMENT_STORAGE        NONE — /etc/kyri and the handoff root keep 0711
```

**`kyri-exec-launcher.py` is a runtime object, not a declared helper.** It is not
in `REQUIRED_HELPERS`; it runs as the coordinator and merely *asks* for
privilege through `sudo`. Its change is a generation object.

The three changed helper digests:

```
kyri-exec-worker.py             2d320630aca559c747522bb528f87172e747f30a182db0fec70e31eca272ddf5
kyri-exec-transition-action.py  b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315
kyri-exec-quota.py              54a9b15c6c6e3b785218d75c91b896f0723d3bf2051ebfca1351c84aa9855ca7
```

**Neither sudoers grant moves.** The pinned digests are `kyri-exec-transition`
and `kyri-exec-reconcile`; both entrypoints are unchanged. The changed objects
are loaded *by* them after elevation.

The repository correctly reports `incompatible` against installed Generation 14
with three stale helpers. Production reports `compatible` and is untouched. Both
answers are right, and the objects must install together.

## 7. Production state

```
CINV-000001   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CRES          0 records
/etc/kyri     root:root 0711        unchanged
handoff root  cschott:cschott 0711  unchanged
libexec       489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86   unchanged
runtime lib   5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84   unchanged
sudoers       f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9   unchanged
fabric        7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
```

`PRODUCTION_MUTATION = NONE`. `CINV_000002_SPENT = NO`.

## 8. Remaining — Task E, the E2E gate

Seven properties must hold in fixture before any deployment. Four are covered:

| property | state |
| --- | --- |
| execution identity reader works through traverse-only `/etc/kyri` | **covered** — authority-anchor suite |
| worker works through traverse-only handoff root | **covered** — handoff-traversal suite |
| launcher surfaces a real bounded refusal reason | **covered** — authority-anchor suite |
| orphan recovery discovers supervised `launch_authorized` with null adapter identity | **covered** — recovery-discovery suite |
| no sibling enumeration is introduced | **covered** — both anchor suites |
| absent-container reconciliation returns `final_absent: true` | **not yet** — needs a fixture reconciler |
| full supervised execution succeeds and produces a terminal `CRES` | **not yet** — the end-to-end shape |

The last two are the remaining work before item G. They need a fixture harness
that drives the whole supervised path without a privileged helper — the
`supervised-execution-e2e` suite is the place for it.

## 9. Next

1. Reviewer accepts this correction and the sweep classification.
2. Finish the two outstanding E2E properties (§8).
3. **Then** deployment preparation (item G): a Generation-15 declaration
   covering the four runtime objects, a helper ceremony covering the three
   privileged objects, and the two stale suites in §5 brought in line with a
   production that has now been invoked once.
4. `CINV-000001` remains permanently `UNRESOLVED` and is not resumed. The next
   production attempt uses `CINV-000002`.
