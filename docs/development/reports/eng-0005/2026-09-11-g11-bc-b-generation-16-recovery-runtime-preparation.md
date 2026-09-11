# ENG-0005 G11-BC-B — Generation-16 recovery runtime preparation

**Status: Generation 16 is PREPARED and NOT INSTALLED. The G11-BC-A correction
is now a declared successor, local validation is GREEN again, and it went green
by declaring a reviewed digest rather than by weakening the check that refused
it.**

The host was rebooted between checkpoints. Every material invariant was
re-derived from the live host rather than carried forward from BC-A, and all of
them hold.

```
RESULT                      PREPARED — reviewer gate, no installation
CURRENT_HOST_GENERATION     15        GEN16_PRODUCTION_INSTALLED   NO
RECOVERY_OLD_SHA256         f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03
RECOVERY_NEW_SHA256         fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0
SAME_DEFECT_CLASS_LIVE_WRONG 0        LATENT_WRONG                 0
COHERENCE_GROUP_R           recovery.py CHANGED, cli.py CARRYOVER
CINV_000002_CONTINUITY_ACROSS_GEN16   YES
STAGE3_REVALIDATES_FABRIC             NO
STAGE3_AUTHORISED           NO        PRODUCTION_INVOKE_AUTHORISED NO
```

Branch `arch/eng-0005-execution-transition`. No production state was changed: no
execution, no recovery, no reconciler, no container, no Fabric write, no Trust
write, no sudoers edit, no installation.

**One thing I could not verify and did not work around** — the execution
identity's Podman store needs operator sudo, which this session does not have.
§2.4 carries the exact commands. It gates the *installation*, not this
preparation.

---

## 1. Reboot reconstruction

Read from the live host, not from BC-A's report.

### 1.1 Repository

```
branch    arch/eng-0005-execution-transition    clean, synchronized with origin
HEAD      91cb1b6  fix(recovery): key lifecycle discovery by the invocation record id
```

### 1.2 The installed runtime IS Generation 15, proved per object

Not asserted from an evidence file. The Generation-15 authority commit was
materialised and compared against every installed object:

```
tools/ objects in /usr/lib/kyri/python compared against ef4f744 : 74
mismatches                                                      : 0
```

All 74 runtime objects are byte-identical to the reviewed Generation-15 source.
The seven Generation-15 matrix targets, individually:

```
helpers.py           6dd93606…  kyri_exec_launcher.py  78c6de90…
verification.py      7a792aaf…  result_content.py      b1c5a89f…
contract_outcome.py  139b77b7…  recovery.py            f44ada7f…
cli.py               7b4fac3e…
```

Every one matches its declared Generation-15 target. The library holds 81 `.py`
objects: the 80 Generation 15 declares plus the one library-root object the
G11-AX helper ceremony created.

The flattened privileged modules are at their accepted ceremony targets — the
LAST accepted one, not any historical one:

```
kyri_exec_transition_action.py  b11a2f19…  G11-BB target
kyri_exec_quota.py              54a9b15c…  G11-BB target
kyri_exec_verify.py             f49c2957…  G11-AX target
kyri_exec_reconcile.py          29175d5a…  G11-AX CREATE target
kyri_exec_transition.py         de264c64…  G11-AX target
```

### 1.3 The pinned entrypoints and the grant directory

```
/usr/libexec/kyri-exec-transition  0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1  MATCH
/usr/libexec/kyri-exec-reconcile   2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77  MATCH

/etc/sudoers.d/  kyri-exec-launch  kyri-exec-reconcile  README
                 kyri-exec-verify  ABSENT
```

Both grants are `-r--r----- root:root`, unchanged since 2026-09-04. The
verification grant is still absent.

## 2. Production invariants, after the reboot

### 2.1 The invocation store

```
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   MATCH
CINV-000001  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
invocation sequence  2          CRES count  0          next  CRES-000001
```

**Lifecycle journal, read from disk:**

```
CINV-000002.000001  {"previous":null,      "sequence":1, "state":"reserved"}
CINV-000002.000002  {"previous":"reserved","sequence":2, "state":"launch_authorized"}
```

`CINV-000001` is at the same pair and stays permanently historical UNRESOLVED.
Nothing in this checkpoint reads, resumes or writes it.

**The launch authorisation survives the reboot intact:**

```json
{"cimp":"CIMP-000001","cinv":"CINV-000002",
 "commitment_digest":"58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da",
 "handoff_root":"/data/kyri/capability-handoff",
 "lifecycle_state":"launch_authorized",
 "profile_digest":"b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923",
 "profile_schema_version":1}
```

### 2.2 The handoff

Structure and modes match `handoff.HANDOFF_MODES` exactly, and the published
bytes still hash to what the authorisation committed to:

```
.              dr-xr-xr-x  0555     ./package      dr-xr-xr-x  0555
./package/main.py  -r--r--r--  0444  683e25ed…
./payload      -r--r--r--  0444     e2914a90…
./profile      -r--r--r--  0444     b707d433…   == the authorisation's profile_digest
./out          drwx------  0700
```

Every member `cschott:cschott`. `CINV-000001`'s handoff is present and untouched.

### 2.3 Fabric and Trust

```
fabric aggregate  3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b   MATCH
trust  aggregate  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   MATCH

fabric validate   findings []   CADV 5  CINST 4  CROUTE 4  CSEL 3  CCON 1  CAPDEF 1  CPKG 1  CHOST 1
trust  validate   valid true    problems []
```

Both byte-identical to the values every checkpoint since G11-BB-R has recorded.
Root Authority is not mounted — no Kyri mount exists on the host.

**New baseline for the next checkpoint:** the `capability-runtime` aggregate is
now `8a1fd4e772e21de76e39541b7c9c301549a43d8f49f15b177e0de0b5bd21f0fd`. It
differs from G11-BB-X's `3f400dea…` because Stage 1 and Stage 2 legitimately
wrote records between them; it did not move during this checkpoint.

### 2.4 What I could NOT observe — operator check required

`/data/kyri/capability` is `drwxr-x--- kyri-capability:kyri-capability` and sudo
in this session requires a password. So the execution identity's image store and
container list are **unobserved**, exactly as G11-BB-Z §2 recorded them.

```
IMAGE_AUTHORITY          OPERATOR_CHECK_REQUIRED
PREEXEC_CONTAINER_STATE  OPERATOR_CHECK_REQUIRED
```

Read-only; run before any Generation-16 installation is authorised:

```bash
# 1. The execution image, under the execution identity.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc \
  --format '{{.ID}} {{.Repository}}:{{.Tag}}'
#   require: 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
#            localhost/kyri-capability-execution:g5

# 2. No kyri-CINV-* container may exist. The seven historical trackb-* stay.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require: NO kyri-CINV-*; trackb-* may remain and must NOT be removed

# 3. Each grant pins the installed entrypoint by digest.
sudo cat /etc/sudoers.d/kyri-exec-launch /etc/sudoers.d/kyri-exec-reconcile
#   require kyri-exec-launch    pins 0d9c8d8c…7ede51a1
#           kyri-exec-reconcile pins 2878fff0…db75798f77
#           /etc/sudoers.d/kyri-exec-verify ABSENT
```

I deliberately did not reach for a workaround. The coordinator-side
`execution_image_available` field is not authoritative for this (G11-BB-X §3.2),
and nothing else I can read answers it.

**Neither gates this checkpoint.** Generation 16 moves no image, no container and
no grant; these are preconditions for the *installation ceremony*, not for its
preparation.

## 3. G11-BC-A root cause, reconfirmed from source

Re-derived from the committed diff, not cited.

`authorise_launch` transitions on the **`CINV`**, so the lifecycle journal is
keyed by the record identity. `_invocation_identity` preferred the **opaque**
one:

```python
-    return record.get("invocation_id") or record.get("invocation_record_id")
+    return record.get("invocation_record_id") or record.get("invocation_id")
```

On production those are different strings — `CINV-000002` against
`g11bb2-second-controlled-invoke` — so `states.get(identity)` missed,
`_container_possible(None)` was false, `adapter_identity` is `None` on the
supervised path, and the record was skipped.

### 3.1 The digests, recomputed rather than trusted

BC-A abbreviated the new digest. Recomputed from the committed source:

```
predecessor (installed, Generation 15)
  f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03
successor (checkout and 91cb1b6)
  fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0
```

Confirmed identical in the working tree and in the commit object, so the
ceremony installs the same bytes the branch carries.

### 3.2 Still exactly the minimal intended change

The whole diff is `+22 −4` in one function: one line of logic and a docstring.

```
CINV records immutable                       YES — no writer added, none touched
invocation_id semantics on invoke unchanged  YES — coordinator.py:180,194 and
                                                   cli.py:220,391 untouched
adapter identity synthesised                 NO
lifecycle journal keying changed             NO
reconciler receives the canonical CINV       YES — reconcile_unresolved passes
                                                   this value; launcher.reconcile
                                                   validates ^CINV-[0-9]{6}$
```

`_invocation_identity` has exactly one caller (`recovery.py:240`), and its own
docstring already declared it returned the CINV. No public signature moves:
`unresolved_invocations`, `reconcile_unresolved`, `execution_safety` and the
`Unresolved` record are unchanged — which is what lets group R move one member
(§5).

### 3.3 RED/GREEN, rerun

```
recovery-discovery     19/19 assertions        PASS
supervision            all assertions          PASS
reconciliation         real containers, Part 4b PASS
```

The eight BC-A assertions that fail against the old ordering still pass against
the new one, including the case whose opaque `invocation_id` differs from the
record id — the production shape the old fixture could not express.

## 4. Same-defect-class sweep, re-derived

I did not take BC-A's table on trust. Every `invocation_id` reference in
`tools/` was re-enumerated and every lifecycle-journal lookup re-read.

**The structural finding that closes it:** `state.py` calls `validate_cinv()` on
every entry point — `current_state` (`:322`), `all_states` (`:333`), `transition`
and `transition_locked`. An opaque identity therefore **raises** rather than
silently missing. The only site that used the value as a bare `dict.get(...)`
key, where a mismatch degrades to silence, was `recovery.py`.

| site | classification |
| --- | --- |
| `recovery.py:240` → `states.get(identity)` | **was LIVE_AND_WRONG → fixed** |
| `recovery.py:272` `cinv = invocation.invocation_id` → `reconciler(cinv)` | **was LIVE_AND_WRONG → fixed by the same change** |
| `cleanup.py:227` | SAFE — `validate_cinv` at `:226` before `current_state` |
| `cleanup.py:330` `all_states(root).items()` | SAFE — iterates journal keys; no join to records |
| `launch.py:402` | SAFE — identity is `_require_cinv`'d upstream |
| `capacity.py:73,92,122` | SAFE — `validate_cinv` on entry; `_consuming` iterates journal keys |
| `inspection.py:129` `opaque = record.get("invocation_id")` | **CORRECT AS OPAQUE** — builds `by_opaque` to detect two records claiming one operator identity. Canonical CINV here would defeat the check. |
| `cli.py:220,391`, `coordinator.py:180,194` | **CORRECT AS OPAQUE** — the invoke path, where the operator's identity is the subject |
| `cli.py:647` `invocation_id=args.cinv` | SAFE — carried only to `record_terminal_result`, which uses it solely as the name of `store.invocation_critical_section(...)`. `store.py:209` states that identity is opaque and the lock is one file, not one per invocation. It is not written into the `CRES`: `RESULT_FIELDS` has no `invocation_id`. |
| `tools/trust/*` `current_state` | DIFFERENT_SEMANTICS — Trust lineage state, a different enum on a different plane |

```
SAME_DEFECT_CLASS_LIVE_WRONG    0
SAME_DEFECT_CLASS_LATENT_WRONG  0
```

Nothing was expanded into Generation 16.

## 5. Generation-16 scope, derived from the machinery

### 5.1 Why a generation is required at all

`g5-preflight.sh:624`: *"The checkout side is absolute: whatever the installed
generation is, the checkout must carry exactly the bytes the row declares."*

`recovery.py` is a declared object, and its row named two admissible successors.
The corrected bytes were a third, so the preflight refused the branch. Confirmed
RED before touching anything:

```
FAIL  the declared object tools/capability/execution/recovery.py is fdad3cec…,
      which is not a declared successor (a93819d1…,f44ada7f…)
G5 preflight validation FAILED: 5
```

### 5.2 Must the unchanged group member be carried? NO — and carrying it would be wrong

The task asked me not to assume this. Read from the installer:

- A coherence group has **no membership registry**. `matrix_groups()` derives
  groups *from the matrix*, so a group is exactly the rows carrying its letter.
- `classify()` (`:462`) tests the **target** digest first. A carryover row whose
  baseline and target are the same value reads `TARGET` unconditionally and can
  never register as `BASELINE` — so it could never contribute to the split
  `require_group_coherence` exists to detect. The row would be incapable of
  failing.
- `verify_unchanged_surface()` begins `is_target "${file}" && continue`.
  Declaring `cli.py` would **remove it from the only check that actually proves
  it did not move**, replacing real evidence with a vacuous row.
- `prepare()` republishes every REPLACE row. A carryover row would rewrite the
  file, contradicting "unrelated installed objects are preserved byte-for-byte".

**So the group is coherent with one member moving, because `cli.py` is the same
bytes in both generations and is therefore at both simultaneously.** The
Generation-15 reason for binding the two — the execution-root argument spanning
the seam — is untouched: no signature on that seam moves (§3.2).

The carryover is declared as reviewable **data** rather than left implicit:

```bash
CARRYOVER=(
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|7b4fac3e…|R"
)
```

`require_carryover_unmoved` checks the source side at the reviewed commit and
refuses an object declared as both a carryover and a matrix row.
`verify_unchanged_surface` checks the installed side, because `cli.py` is not a
target. The suite proves both, including that drift in `cli.py` is still refused
(§6 case E).

### 5.3 The object manifest

```
CREATE      (none)
REPLACE     tools/capability/execution/recovery.py
REMOVE      (none)
CARRYOVER   tools/capability/cli.py                    group R, not republished
```

| field | value |
| --- | --- |
| repository path | `tools/capability/execution/recovery.py` |
| installed path | `/usr/lib/kyri/python/tools/capability/execution/recovery.py` |
| predecessor digest | `f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03` |
| successor digest | `fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0` |
| mode | `0444` root:root |
| coherence group | `R` — supervised recovery discovery |
| operation class | `REPLACE` |

```
source authority       91cb1b601972ab43cc4c8b3335ed5022cd50158b   (G11-BC-A)
predecessor authority  ef4f7446200b668f8dcbf34d180c5102270f19f6   (Generation 15)
library object count   80 -> 80   (+1 G11-AX helper CREATE present = 81 -> 81)
```

`ef4f744` is an ancestor of `91cb1b6`, which is an ancestor of HEAD. No
placeholder commit was needed: the reviewed bytes already exist in history,
unlike Generation 15, which had to be re-pinned after its first attempt.

### 5.4 What Generation 16 deliberately is not

```
sudoers change            NO   recovery.py is not an entrypoint and is absent
                               from helpers.REQUIRED_HELPERS
helper ceremony           NO   no helper, no entrypoint, no worker moves
Fabric / Trust change     NO   neither is reachable from this ceremony
invocation mutation       NO   the ceremony reads no capability record
OUTSIDE_EXECUTION_CLOSURE ()   empty — recovery.py IS in the import closure of
                               tools.capability.cli, so no exception is needed
```

Generation 15 needed three closure exceptions; this one needs none, which is the
strongest state that declaration can be in.

### 5.5 The property a one-row generation loses, replaced rather than dropped

Generation 15 published `helpers.py` first so execution shut before any other
object became observable. That lever does not exist here and **is not needed**: a
single `mv` onto a single pathname has no intermediate state, so a concurrent
reader sees the whole predecessor or the whole successor.

I did not silently inherit that argument. `require_fail_closed_first` is replaced
by `require_single_object_transaction`, which **halts** if the matrix ever grows
a second row, is in a group other than R, or declares anything but a REPLACE —
forcing whoever adds a row to decide what shuts execution, as Generation 15 had
to. The suite drives a mutated two-row installer and asserts the refusal names
that property.

Rollback still restores in reverse order. With one row that is the same order;
the loop is kept rather than simplified away, because it is the property a
multi-row successor would need back.

### 5.6 Execution readiness is UNCHANGED, unlike Generation 15

Generation 15 deliberately drove helper compatibility to `incompatible`. This one
cannot: it moves nothing the readiness gate reads. The fixture reports
`compatible` before, during and after, and the suite asserts it at every
interruption point. An operator should not go looking for an intermediate state
this generation does not produce.

## 6. TDD and governance testing

### 6.1 RED first

```
BEFORE  bash tests/test-capability-execution-g5-preflight.sh
        FAIL  the declared object …/recovery.py is fdad3cec…,
              which is not a declared successor (a93819d1…,f44ada7f…)
        G5 preflight validation FAILED: 5

AFTER   G5 preflight validation passed.      rc=0
```

**It went green by declaring, not by relaxing.** The change is one digest
appended to one row's successor list, plus the comment explaining why:

```
"tools/capability/execution/recovery.py|CREATE|ABSENT|a93819d1…,f44ada7f…,fdad3cec…"
```

No check was weakened, no comparison became a wildcard, nothing is derived from
git, and the predecessors stay listed because the rows are cumulative. The
`generation-succession` suite — which drives the real classification functions
extracted from the preflight by name — still passes unchanged, including
requirement 10 (a declared successor does not retroactively bless unrelated
bytes) and the refusal of a successor declared on a different row.

### 6.2 The recovery semantics, A–H

| | claim | evidence |
| --- | --- | --- |
| A | an opaque `invocation_id` differing from the CINV is discovered | `recovery-discovery` 19/19; reconciliation Part 4b with `invocation_id=g11bbz-opaque-invoke`, `invocation_record_id=CINV-000044` |
| B | the reconciler is called with the canonical CINV | Part 4b: *"the real reconciler was asked about the CINV"* — and the **real** reconciler accepting it is the proof, since it validates `^CINV-[0-9]{6}$` |
| C | `execution_safety` inspects rather than skips | `checked == 1` on both the refusing and the proving paths; `checked == 0` only for an empty store |
| D | a refusing reconciler leaves a real orphan untouched and reports blocking | Part 4b: container still `'running'`, verdict `'not-ready'`, `['CINV-000044']` blocking |
| E | the governed reconciler proves disposal | container `'absent'`, verdict `'ready'` |
| F | `CINV` remains immutable | no writer added; `record_terminal_result` never touches the invocation; production digests unchanged (§11) |
| G | no synthetic `CRES` from recovery discovery | `command_recover` emits `results_written: 0` and writes nothing; CRES count still 0 |
| H | no unrelated invocation affected | Part 4b runs `CINV-000044` in the suite's disposable Podman store, torn down by its trap |

### 6.3 The Generation-16 ceremony suite

`tests/test-capability-execution-generation16-installer.sh` — new, host-only,
unprivileged, fixture-only. The fixture is **reconstructed, not copied**: the
path set comes from the installed library root, the bytes from the Generation-15
authority, and the helper-governed objects from each accepted ceremony's own
matrix. Its Generation-15 evidence file records G11-BB's *predecessor* bytes,
because that ceremony published after Generation 15 committed — which is what
the real file contains.

```
declared shape          matrix is one row, one group, no CREATE, no REMOVE
                        the carryover is byte-identical at BOTH authorities
                        the correction is in the reviewed bytes; the defect is gone
--verify                accepts the baseline, writes nothing, no __pycache__
--install               completes; count unchanged; 0444; correction installed;
                        module imports
CARRYOVER               cli.py byte-and-mode identical across the install
--verify-installed      accepts the complete target
must not have moved     no grant written or changed; no /usr/libexec object changed;
                        helper compatibility unchanged (compatible -> compatible)
refusals                unknown REPLACE baseline; drift in the group-R carryover
                        (not a matrix row, still refused); drift in an unrelated
                        carried-over object; a ceremony-governed object at
                        undeclared bytes; a SUPERSEDED ceremony state; an
                        ungoverned extra object; a missing accepted object
gates                   verify grant present halts; a grant pinning absent bytes
                        halts; an undeclared kyri-* grant halts
single-object property  a mutated TWO-ROW installer is refused, and the refusal
                        names the atomicity property that stopped holding
carryover collision     an object declared as both a row and a carryover is reported
operator ceremony       executed against a stub: stage order, fail-fast at each
                        stage, and an unexpected journal stops everything before
                        any installer runs and is left untouched
crash matrix            10 interruption points; at each one the library is at
                        exactly one of two states, residue only where cleanup
                        itself failed, carryover untouched, readiness unchanged
```

```
Generation-16 installer validation passed.
```

**Two harness defects the run caught, in my own test rather than in the
installer.** `grep -c` prints its count *and* exits non-zero when that count is
zero, so a `|| printf '0'` fallback appended a second zero and every "ran 0
times" assertion was comparing against `"00"` — three ceremony cases were passing
their refusal but failing their assertion. And the carryover-collision case
initially reused the two-row installer, where `require_single_object_transaction`
correctly halts *first*, so the collision check was never reached and the case
proved nothing. Both are fixed; the collision now runs against a one-row
installer with a colliding carryover.

## 7. The proposed production ceremony

`provisioning/execution/install-generation-16.sh`, five modes, fail-closed
throughout. Prepared and **not run**.

```
--verify-source     reviewed bytes only; reads no installed state
--verify            is this host a Generation-15 host ready for it?
--install           the transaction
--verify-installed  is this host a whole Generation 16?
--recover           resolve an interrupted transaction
```

It identifies the predecessor by digest and refuses an unexpected one
(`prepare` halts unless the target is exactly `f44ada7f…`); pins both source and
installed-target digests; enforces coherence-group requirements; preserves
unrelated installed objects byte-for-byte through `verify_unchanged_surface`
against the accepted Generation-15 evidence plus both accepted helper ceremonies;
fingerprints the privileged surface and the authority namespace before and after
and reports any change; touches no invocation record, no Fabric path, no Trust
path and no grant; removes its transaction artefacts after a successful commit;
and journals every irreversible step so `--recover` reads a fact rather than
inferring one.

Its namespace is its own — `/root/kyri-gen16-transaction`,
`.kyri-gen16.new`, `.kyri-gen16.gen15` — so Generation 15's retained journal is
predecessor evidence that is never read as this transaction's state. That
mistake cost the first real Generation-14 attempt a checkpoint.

**The exact operator ceremony** (`provisioning/execution/gen16-operator-ceremony.txt`,
executed against a stub by the suite, so its control flow is proven rather than
described):

```bash
set -Eeuo pipefail
cd /opt/schott-platform

sudo test ! -e /root/kyri-gen16-transaction/journal \
  || { printf 'STOP: a Generation-16 transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-gen16-transaction \
  || { printf 'STOP: Generation-16 transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

sudo test -f /root/kyri-gen15-library-digests.txt
sudo test -f /root/kyri-gen15-helper-digests.txt

sudo bash /opt/schott-platform/provisioning/execution/install-generation-16.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-16.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-16.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-16.sh --verify-installed
```

**No Stage 3 in this ceremony, by construction.**

### 7.1 Expected post-install state

```
installed recovery.py        fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0  0444 root:root
installed cli.py             7b4fac3e…  UNCHANGED
library object count         81  UNCHANGED
helper compatibility         compatible    supervision_ready  true    UNCHANGED
both entrypoints             0d9c8d8c… / 2878fff0…  UNCHANGED
sudoers                      two grants, verify grant absent  UNCHANGED
Fabric 3fa32b83…  Trust 53605e4e…                             UNCHANGED
CINV-000002 923ff0d7…  launch_authorized  seq 2  CRES 0        UNCHANGED
new evidence                 /root/kyri-gen16-library-digests.txt
                             /root/kyri-gen16-helper-digests.txt
preserved                    /root/kyri-gen15-*-digests.txt
transaction artefacts        none
```

The one observable behavioural change: `capability recover` stops being vacuous.
It will discover both invocations, invoke the privileged reconciliation helper
for each, and report `NOT_READY` until each proves `final_absent`. **That is a
real privileged action and installing Generation 16 does not authorise it.**

## 8. CINV-000002 continuity across Generation 16

```
CINV_000002_CONTINUITY_ACROSS_GEN16 = YES
```

Not inferred from the state machine. Traced through the actual Stage-3 path.

### 8.1 recovery.py is not on the Stage-3 path at all

```python
# cli.py:737, inside command_recover
    from .execution import recovery
```

A **function-local** import. `recovery` appears nowhere in cli.py's module-level
imports, and `command_execute` never references it. So the single object
Generation 16 moves is not loaded by Stage 3.

`execution_safety` is called from exactly one place — `command_recover`
(`cli.py:753`). BC-A said this and I re-confirmed it: **`command_execute` does
not consult it**, so recovery discovery does not gate Stage 3 before or after
this generation.

### 8.2 What Stage 3 actually binds to, and what revalidates

| binds to | revalidated at Stage 3? | moved by Gen16? |
| --- | --- | --- |
| generation identity | **no such binding exists** — nothing in `tools/capability/` reads a runtime generation number or either evidence file | n/a |
| profile digest | YES — `supervised_binding` re-hashes the published profile and refuses unless it equals the digest the authorisation committed to | NO |
| handoff contents | YES — via that same re-hash, and `_published_bytes` reads through the anchored roots | NO |
| commitment digest | written at Stage 2, read back; re-derived MATCH in §2.1 | NO |
| runtime/helper digests | YES — `helpers.compatibility()` through `_helper_launcher()`, plus the sudo grants pinning both entrypoints by digest | NO |
| image identity | YES — `profile.py` compares declared `oci_image_id` against observed | NO |
| package digest | bound transitively through the profile and the published package | NO |
| execution policy | the privileged helper's own, unchanged bytes | NO |

`current_generation` in `authorisation.py:142` and `cli.py:260` is the
**implementation-authority** generation — which CIMP is admitted — a different
plane from the runtime deployment generation. It is not moved by this ceremony
and is fingerprinted before and after to prove it.

**So every value Stage 3 revalidates is byte-identical across Generation 16, and
the one object that changes is never loaded.** An already `launch_authorized`
CINV continues safely.

## 9. The expired Fabric lease

```
FABRIC_LEASE_EXPIRED                              YES
STAGE1_DECISION_WAS_IN_WINDOW                     YES
STAGE3_REVALIDATES_FABRIC                         NO
EXPIRED_LEASE_BLOCKS_EXISTING_LAUNCH_AUTHORIZED_CINV  NO
```

Re-derived from current source after the Gen16 change, not carried from
G11-BB-X.

### 9.1 The facts

```
CINST-000004  admitted_at     2026-09-07T14:15:00-05:00
              admitted_until  2026-09-10T21:30:00-05:00
              lifecycle_state admitted        superseded_by  (absent)
CINV-000002   requested_at    2026-09-09 11:50:22-05:00     <- inside the window
now                           2026-09-11T07:23-05:00        <- outside it
```

### 9.2 The eligibility evaluation has exactly one reachable site

```
_window_open(instance, instant)     fabric_evidence.py:264
  called from                       fabric_evidence.py:335, inside verify_selected_evidence
verify_selected_evidence            called from exactly two places:
  coordinator.py:110                inside prepare_invocation   <- Stage 1
  cli.py:396                        inside command_preflight    <- a Stage-1 rehearsal
```

Neither is Stage 3. And `command_execute`'s parser takes five arguments —
`--expected-uid --expected-gid --cinv --actor --recorded-at` — with **no Fabric
or Trust store root**, so Stage 3 has no path to the Fabric store to re-open the
question with. A grep of the whole Stage-3 surface —
`supervision.py`, `launch.py`, `profile.py`, `worker.py` and the five privileged
helper modules — returns no Fabric store access, no CSEL lookup, no CINST lookup,
no CADV freshness evaluation, and no `admitted_until` reference. The only hits
are two comments in `launch.py` saying so: *"Fabric selection and package
resolution happened at preparation and are read back from the durable invocation
record; Trust is not consulted at all."*

### 9.3 Why expiry cannot change a decision already made

```python
def _window_open(instance, instant):
    """The admission window, as recorded, containing the supplied instant."""
    ...
    return start <= instant < end
```

The instant is **supplied**, never read from a clock. And there is **no
wall-clock call anywhere in `tools/capability/`** — `grep -rn
"datetime.now\|utcnow\|time.time()\|date.today"` returns nothing. Every instant
is operator-supplied via `--requested-at` or `--recorded-at`.

So expiry is not a state the runtime can drift into. It changes exactly one
thing: a **new** invocation prepared against `CINST-000004` today would supply a
current instant, fail `_window_open`, and be refused with `REASON_WINDOW`. That
is correct and unchanged.

**Expiration grants no new authority and weakens no old decision.** The Stage-1
decision was made in-window, against a record that is immutable evidence of it;
the lease bounds when a decision may be *made*, not how long a decision already
made remains true. Stage 3 asks no eligibility question, so there is nothing for
the boundary to close.

**The Gen16 transition does not disturb this.** Generation 16 moves `recovery.py`
only, which contains no Fabric reference and is not loaded by Stage 3 (§8.1).

**No Fabric renewal was performed, and none is required for Stage 3.** An
operator wanting a *new* invocation does need a fresh CADV/CINST/CSEL chain; that
is a separate governed decision and is not proposed here.

## 10. Validation

```
CHANGED
  provisioning/execution/g5-preflight.sh              +31 -1   (one declared
                                                               successor digest
                                                               + the reason)
  tools/dev/run-validation.sh                         +10      (register the suite,
                                                               both step totals)
  .github/workflows/ci.yml                            +7       (register the suite)
  tests/host-only.manifest                            +1

CREATED
  provisioning/execution/install-generation-16.sh     1880
  tests/test-capability-execution-generation16-installer.sh  824
  provisioning/execution/gen16-operator-ceremony.txt  31

FOCUSED SUITES
  recovery-discovery 19/19          reconciliation (real containers)  PASS
  supervision        PASS           generation succession             PASS
  generation-15 installer PASS      generation-16 installer           PASS
  g5 preflight       PASS           static                            PASS
  developer experience PASS

shellcheck   clean (0.9.0, the version CI runs)

LOCAL_QUICK  PASS  110/110 steps
LOCAL_FULL   PASS  135/135 steps
```

### 10.1 Two registration defects the validator caught, and I fixed rather than worked around

Adding a suite is not just adding a file, and the repository enforces both halves.

`test-developer-experience.sh` failed with *"local validation runs suites CI
omits: tests/test-capability-execution-generation16-installer.sh"*. The suite was
registered in `run-validation.sh` and not in `.github/workflows/ci.yml`. That
check exists so a suite cannot be local-only by accident, and it was right — CI
now runs it (where it reports `HOST_ONLY_SKIP`, which is the declared and
asserted behaviour, not a silent pass).

Then the run ended *"step count mismatch — declared 109, executed 110. Every
check ran, but the declared total is wrong."* `TOTAL_STEPS` is deliberately read
off a real run rather than computed, so both totals were re-measured rather than
incremented on the assumption the suite runs in both modes: quick `109 -> 110`,
full `134 -> 135`, each confirmed by a completed run.

Neither was suppressed. Both are the kind of failure that is cheap now and
expensive later.

CI does not exercise the host-only surface — `test-capability-execution-generation16-installer.sh`
reports `HOST_ONLY_SKIP` anywhere without an installed runtime, and the
manifest and `test-static.sh` enforce that it is declared in both directions. For
that surface **the local host result is the authority**, and it is green.

## 11. Production is unchanged

Re-read after every change in this checkpoint:

```
installed host generation        15                      UNCHANGED
installed recovery.py            f44ada7f…               the PREDECESSOR; the
                                                         correction is NOT installed
CINV-000002                      923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
CINV-000002 lifecycle            launch_authorized
invocation sequence              2
CRES count                       0        CRES-000001 unspent
kyri-CINV-000002 container       none created by this checkpoint
fabric aggregate                 3fa32b83…               byte-identical
trust  aggregate                 53605e4e…               byte-identical
sudoers                          two grants, verify grant absent, unchanged
Root Authority                   unmounted
```

`/root/kyri-gen16-transaction` is **not observable** to me — `/root` is
`drwx------ root:root` and this session has no password-less sudo. I am not
claiming it is absent. Nothing in this checkpoint ran as root or could have
created it, and the operator ceremony's first two lines check for it and refuse
before any installer runs, which is where that check belongs.

```
NO EXECUTION. NO RECOVERY. NO RECONCILER. NO CRES. NO CONTAINER.
NO FABRIC WRITE. NO TRUST WRITE. NO SUDOERS EDIT. NO INSTALLATION.
```

## 12. STOP — the reviewer gate

```
GEN16_PREPARED                YES      GEN16_PRODUCTION_INSTALLED   NO
STAGE3_AUTHORISED             NO       PRODUCTION_INVOKE_AUTHORISED NO
CINV_000001_RESUME_AUTHORISED NO       CRES_000001_SPENT            NO
```

Generation 16 is the minimal legitimate successor: one object, one group, one
rename, no helper, no grant, no Fabric, no Trust, no invocation touched.

The next step is **reviewer acceptance, followed by a separate
operator-authorised Generation-16 production installation ceremony** (§7), with
the §2.4 operator precheck returned first.

Stage 3 stays unauthorised and is not part of that ceremony. Whether to run it
after Generation 16 is installed is a separate decision, and the §2.4 image and
container checks would need to be current at that point.
