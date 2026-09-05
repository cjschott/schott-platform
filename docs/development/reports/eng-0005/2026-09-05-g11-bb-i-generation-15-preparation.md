# ENG-0005 G11-BB-I — Generation 15, prepared

**Status: Generation 15 built and proven in fixture. Not installed.** Production
untouched. `CINV-000001` byte-identical, `CINV-000002` unspent. No privileged
helper, no grant, no Fabric change.

Branch `arch/eng-0005-execution-transition`, HEAD `6f7cef1`.

*This report replaces the STOP that stood at this path. The Option-C ruling
resolved the question it stopped on; the derivation below is re-done from
scratch against that ruling, not carried forward.*

---

## 1. The set, re-derived

Mechanically, from the accepted installed Generation-14 authority to reviewed
source at `ef4f744`. **It matches the ruled Option-C set exactly**, so no second
stop was needed.

```
GEN15_REPLACE   5      GEN15_CREATE   2      GEN15_REMOVE   0
GEN15_CARRYOVER 73     GEN15_OBJECTS  80 governed (81 flat, +1 helper-published)
```

| # | path | Gen-14 accepted | Gen-15 reviewed | op | group |
| --- | --- | --- | --- | --- | --- |
| 1 | `tools/capability/execution/verification.py` | `ed5b49ed…` | `7a792aaf…` | REPLACE | V |
| 2 | `tools/capability/execution/result_content.py` | ABSENT | `b1c5a89f…` | CREATE | V |
| 3 | `tools/capability/execution/contract_outcome.py` | ABSENT | `139b77b7…` | CREATE | V |
| 4 | `tools/capability/execution/recovery.py` | `a93819d1…` | `f44ada7f…` | REPLACE | R |
| 5 | `tools/capability/cli.py` | `752951f7…` | `7b4fac3e…` | REPLACE | R |
| 6 | `tools/capability/execution/helpers.py` | `74b84015…` | `6dd93606…` | REPLACE | H |
| 7 | `provisioning/execution/kyri-exec-launcher.py` → `kyri_exec_launcher.py` | `269258f3…` | `78c6de90…` | REPLACE | H |

**Object accounting.** 79 installed `.py` minus the one helper-ceremony `CREATE`
into the library root (`kyri_exec_reconcile.py`) gives the governed 78; two
CREATEs make 80. Flat count is not generation count, and the installer computes
that the same way Generation 14 does rather than counting directory entries.

**Correctly excluded.** `kyri_exec_transition_action.py` and `kyri_exec_quota.py`
also differ, and both are **privileged helpers** belonging to Phase 8. The
installer refuses any matrix row naming a helper, a grant or a deployment
identity — 14 privileged objects are asserted outside this ceremony.

## 2. Source authority

```
GEN15_SOURCE_AUTHORITY = ef4f7446200b668f8dcbf34d180c5102270f19f6
```

Chosen, not defaulted to HEAD. It carries the exact reviewed bytes for all seven
objects — verified row by row — and every correction commit is its ancestor:
`d11e141` (recovery discovery), `b74f2fb` (anchors, launcher diagnostic, helper
declaration), `606cea3`, `0f47281`. The Generation-14 authority `946be55` is
also its ancestor, which the installer checks.

## 3. Coherence groups, derived

Three, and each is a group because its members are incoherent apart.

**V — the runtime-side verification surface.** The installed `verification.py`
predates `03a2e90` and **cannot import**: it asks `worker.py` for `WORKER_GID`
and `WORKER_UID`, which that commit removed. Replacing it alone would leave two
modules a live contract already names absent; creating those alone would leave a
module that fails to import. Neither half is a coherent state.

**R — supervised recovery discovery.** `recovery.py` discovers an interrupted
invocation from the lifecycle journal; `cli.py` opens the execution root and
threads it in. One without the other is either a root nothing reads or a read
nothing passes.

**H — helper declaration and refusal reporting.** `helpers.py` carries the
digests of the three objects Phase 8 will move; `kyri_exec_launcher.py` is the
seam that carries a helper refusal back.

## 4. Entry closure — the honest answer

**`result_content.py` and `contract_outcome.py` do not enter the closure
naturally, and neither does `verification.py`.** The closure is computed from
the production execution roots and is **73 modules**; none of the three is
reachable from them.

**They were not whitelisted into the closure.** The surplus check still refuses
any matrix row the closure does not require. What was added is a separate,
explicitly reasoned declaration — `OUTSIDE_EXECUTION_CLOSURE` — naming each one
with why it is governed, and **anything not named still halts**:

- **`verification.py`** — reached only from
  `/usr/libexec/kyri-exec-verify-worker.py`, a governed *alternative* entrypoint
  that is not a production execution root. It has been an installed governed
  object since Generation 13 and is part of the accepted Generation-14 surface.
- **`result_content.py`** — named **by path** as an authority in a live Fabric
  record: `CCON-0001.response_shape.content.authority`. A contract naming a
  module the deployment does not carry is a claim of enforcement no code
  performs.
- **`contract_outcome.py`** — the declared translation between the runtime's
  `records.OUTCOME_CLASSES` and a contract's `failure_modes`. It exists so that
  *"every failure this capability can suffer is one the contract declares"* is
  checkable rather than asserted.

Adding them to `CLOSURE_ROOTS` would have meant inventing an import the runtime
does not perform — forging the evidence the closure check exists to read.

`GEN15_ENTRY_CLOSURE = 73 modules, PASS`.

## 5. The installer

`provisioning/execution/install-generation-15.sh`, built from the
**Generation-13** transaction model rather than Generation 14 — 13 already
carries CREATE rows, coherence groups and CREATE rollback, and 14 is a
degenerate single-REPLACE case. No new transaction framework was invented:
`--verify-source`, `--verify`, `--install`, `--verify-installed`, `--recover`,
PREPARE/COMMIT, journal, atomic publication by rename, predecessor bytes
preserved for rollback.

## 6. The fixture is reconstructed, not copied

The ruling forbade copying production wholesale, and copying would have made the
fixture agree with production by construction.

**The path set comes from the accepted Generation-14 surface; the bytes come
from reviewed git objects.** Every object is materialised from `946be55`
**except `verification.py`, which is taken from `16f285e`** — because the
installed Generation-14 runtime *does not match its own source authority* for
that one object. That mismatch is the defect this generation repairs, and it is
precisely why the baseline had to be reconstructed per object rather than from a
single commit.

## 7. Results

```
GEN15_INSTALLER                READY
GEN15_VERIFY_NON_MUTATING      PASS   production and fixture; manifests identical, no __pycache__
GEN15_FIXTURE_VERIFY           PASS   accepts the reconstructed 79-object baseline
GEN15_FIXTURE_INSTALL          PASS   79 -> 81 objects
GEN15_FIXTURE_VERIFY_INSTALLED PASS   complete target accepted
GEN15_INSTALLED_IMPORT         PASS   the repaired verification surface imports as a whole
GEN15_UNKNOWN_BYTES            PASS   REPLACE baseline, carryover object
GEN15_CREATE_COLLISION_REFUSAL PASS   a pre-existing CREATE pathname is refused
GEN15_RECOVERY                 PASS   all ten publication boundaries
GEN15_VERIFICATION_COHERENCE   PASS
```

**Recovery, at every boundary the installer can be interrupted at** — `stage`,
`staged`, `prepared`, `precommit`, `committing`, `publish`, `verify`,
`postcommit`, `evidence`, `cleanup`. Each leaves either the **exact
Generation-14 library** or **every matrix row at its Generation-15 bytes**;
never a mixed matrix. Residue appears only at `cleanup`, where the step that
removes it is the step that failed.

**`--verify` non-mutation was proved twice**, including against live production
with a full before/after manifest of the library root: identical, and no
bytecode created.

## 8. Verify authority stays closed

```
VERIFY_GRANT_PRESENT         NO
VERIFY_ENTRYPOINT_AUTHORISED NO
SUDOERS_CHANGE_REQUIRED      NO
```

Asserted by the suite, not assumed: the installation writes no grant and touches
no `/usr/libexec` object. Group V repairs the verification **library**; the
entrypoint that would use it stays ungranted. The verify entrypoint was not
added to any permitted-helper set and was not executed.

## 9. Three things the guards caught

Each was my error and each was caught by a check that already existed.

1. **The fixture was too large — twice.** It first copied every `tools/*.py`
   (186 objects), then every `provisioning/execution/kyri-exec-*.py` (86). Both
   times the installer's own object-count check refused. The fix was to take the
   *path set* from the accepted generation in both places.
2. **A provisioning artefact must not be executable.** I ran `chmod +x` on the
   installer; the provisioning suite refused. Its siblings are `0664` and are
   invoked as `bash <path>` so they cannot be run by accident.
3. **The suite is host-only and I had not said so.** It reads
   `/usr/lib/kyri/python` for the path set, so CI failed on a runner with no
   installed runtime. Now declared through `host_only_requires` and registered
   in `tests/host-only.manifest`.

Also: the first clean-clone check used `--depth 1` and the fixture could not
reach `946be55`. Re-run with full history it passes, and CI uses
`fetch-depth: 0`.

## 10. Validation

```
Gen-15 focused suite   PASS
LOCAL_QUICK            PASS   107/107
LOCAL_FULL             PASS   132/132   at 6f7cef1
GITHUB_CI              PASS   6/6 at 6f7cef1
CLEAN_CLONE_VERIFY     PASS   full clone of the pushed commit, focused suite green
working tree           clean; HEAD == pushed branch head
```

## 11. Production precheck

```
HOST_GENERATION   14
runtime           5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84  unchanged
libexec           489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86  accepted predecessors
sudoers           f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9  unchanged
verify grant      ABSENT
CINV-000001       1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa  UNRESOLVED
CRES              0
fabric            7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96  unchanged
window remaining  22h 14m
```

Production would be eligible on every count. **The window is not a deployment
deadline** and nothing was renewed: `CHAIN_RENEWAL_BEFORE_CINV_000002 = YES`,
after the corrected surface is installed and accepted.

Historical production state is tolerated and untouched throughout — `CINV-000001`
exists, is unresolved, and its handoff remains published. Nothing in this
generation encodes "production has never invoked", and generation installation
is runtime deployment, not execution-record cleanup.

## 12. Next

Reviewer acceptance, then Phase 8: the three-object helper ceremony, with its
delta re-derived rather than carried from here.
