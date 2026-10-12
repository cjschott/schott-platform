# ENG-0005 G11-Z2 — Generation-12 production installation and live runtime verification

**Date:** 2026-08-29
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `a008b263a529237354ce04c9b6f13fa26ba254e9`
**Predecessor report:** `docs/development/reports/eng-0005/2026-08-29-g11-z1-generation-12-installer-correction.md`
**Reviewed installer authority:** `1313df019472a73e139cfc294ee8e016ad1355c0`
**Implementation commit:** none — no runtime source changed in this checkpoint

Generation 12 is installed on the production host. The installed runtime is a
whole Generation 12, proved by reading back the objects rather than by trusting
the installer's summary — which matters here, because that summary is wrong
about which generation it just installed.

No capability was staged and none was invoked.

---

## 1. Fresh-session reconstruction

All authority was rebuilt from Git and the live host. No state, shell variable,
monitor, background job or memory from any earlier session was relied on.

| Step | Result |
| --- | --- |
| `git status --short` | clean, before and after |
| `git branch --show-current` | `arch/eng-0005-execution-transition` |
| `git fetch origin` / `git pull --ff-only` | `Already up to date` |
| `git rev-parse HEAD` | `a008b263a529237354ce04c9b6f13fa26ba254e9` |
| `git rev-parse origin/arch/eng-0005-execution-transition` | identical to HEAD |
| `013fac1…` ancestor of HEAD | yes |
| `a008b26…` ancestor of HEAD | yes |

## 2. G11-Z1 corrections re-verified from current source

Confirmed mechanically against `provisioning/execution/install-generation-12.sh`,
not carried across from the predecessor report.

| Required property | Evidence |
| --- | --- |
| G12 transaction root | `TRANSACTION_ROOT="/root/kyri-gen12-transaction"` (line 87) |
| No G12 state on the predecessor path | the sole `kyri-gen11-transaction` occurrence is line 80, a comment; zero executable lines |
| G12-specific fault namespace | `KYRI_GEN12_FAIL_AT` ×2, `KYRI_GEN11_FAIL_AT` ×0 |
| REPLACE implemented | `prepare()` line 836; commit path line 1017; rollback restore line 1020 |
| Retained backup survives | the Generation-11 `rm -f` is gone from `prepare()`; the three surviving removals are in the never-published, post-rollback and post-COMMITTED paths only |
| Mixed directories valid | `require_same_filesystem()` judges each row against its own target directory, walking to the nearest existing ancestor for a not-yet-created one |
| G11 evidence is predecessor authority only | read via `BASELINE_LIBRARY_EVIDENCE` / `BASELINE_HELPER_EVIDENCE`; `GEN11_COMMIT` is the ancestry baseline |

Matrix disposition as declared: **6 REPLACE + 13 CREATE = 19**.

## 3. Step 1 — `--verify-source` (non-privileged)

```
ok       repository at arch/eng-0005-execution-transition, reviewed authority 1313df019472a73e139cfc294ee8e016ad1355c0 present and an ancestor of HEAD
ok       19 Generation-12 source objects match the reviewed commit 1313df019472a73e139cfc294ee8e016ad1355c0
ok       the import closure of tools.capability.cli tools.capability.execution.worker kyri_exec_transition kyri_exec_transition_action kyri_exec_verify kyri_exec_quota closes over the declared surface (59 modules)
ok       the reviewed source carries the G11-X per-invocation operation and scope authority
ok       the reviewed source carries the G11-Y current-eligibility revalidation
note     no installed path was read for state and none was written

Generation 12 source verification: all checks passed. 19 object(s) would change.
```

Exit status 0. **PASS.**

## 4. Pre-install host state, taken independently

Read directly before the operator ceremony, reproducing the G11-Z1 forensics:

| Property | Observed |
| --- | --- |
| Installed `.py` objects | 57 |
| Aggregate digest | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` |
| Six REPLACE targets | all at declared baseline digests; mtimes 2026-08-12 → 2026-08-19 |
| Thirteen CREATE targets | absent (probed individually: `absent=13 present=0`) |
| `tools/trust/` | absent |
| Transaction residue | none |
| `/etc/sudoers.d/` | `README` only |
| Privileged helpers | five, digests recorded |
| Fabric / Trust / Evidence+Artifacts | 21 / 26 / 3 files, fingerprints recorded |

## 5. Operator ceremony — recorded as reported

`--verify`, `--install` and `--verify-installed` each completed with no FAIL and
no STOP. The operator-observed lines are recorded **verbatim and unsanitised**,
including the incorrect generation labels, because they are the subject of §8.

**`--verify`**

- 19 Generation-12 source objects match reviewed commit
- import closure closes over 59 modules
- installed runtime exactly accepted Generation-11 baseline, 57 objects
- no transaction residue
- sudoers gates closed
- every target stages beside itself on library filesystem
- host ready for Generation-12 installation
- `19 CREATE operations`
- object count `57 -> 70`

**`--install`**

- PREPARE complete: 19 objects staged
- 13 pathnames reserved
- all 19 prepared objects verify
- COMMIT complete: 19 objects created and verified
- `Generation-11 evidence written; Generation-11 evidence preserved`
- transaction artefacts removed
- `all 19 installed Generation-11 objects correspond to reviewed commit`
- `every Generation-11 runtime object is exactly its accepted baseline`
- `Generation 11 / installed Fabric dependency closure install: all checks passed`

**`--verify-installed`**

- no FAIL/STOP
- Trust package contains only declared objects
- sudoers closed
- no transaction artefacts
- `Generation 11 / installed Fabric dependency closure verify-installed: all checks passed`

## 6. Live generation forensics — the actual host

Taken by reading the installed objects. The installer's prose is **not** the
evidence for anything in this section.

| # | Property | Observed | Verdict |
| --- | --- | --- | --- |
| 1 | Installed `.py` objects | **70** | as declared |
| 2 | Aggregate digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` | new |
| 3 | Six REPLACE paths | all six at declared **Generation-12 target** hashes, `0444 root:root` | replaced |
| 4 | Thirteen CREATE paths | all thirteen present at declared target hashes, `0444 root:root` | created |
| 5 | `tools/trust/` | 10 modules, `0755 root:root`, all `0444` | exactly the declared package |
| 6 | Undeclared Trust modules | none; `decisions/decision/authority/issuance/revocation/attestation` all absent | decision surfaces excluded |
| 7 | Privileged helpers | all five byte-identical to the pre-install digests | excluded, unchanged |
| 8 | `/etc/sudoers.d/` | `README` only | both grants absent |
| 9 | Transaction residue | zero `.prepared` / `.kyri-gen12.gen11` | clean |

Every one of the 19 matrix rows classified `G12_TARGET`; the tally is exactly
`13 CREATE` + `6 REPLACE`.

**No foreign object appeared.** The 70 installed pathnames decompose exactly as
70 = 19 declared matrix paths + 51 carry-over paths, with no path outside the
union. Every declared matrix path is installed.

**The 51 carry-over objects are byte-unchanged.** The pre-install manifest was
validated as genuine Generation-11 evidence by re-aggregating it to
`80f9dee2…07f5b`, then compared file-by-file against the post-install manifest:
51 compared, **0 differing**.

**Host generation: whole Generation 12.** Not mixed, not partial.

### Items 10–12 — journal and `/root` evidence

`/root` is not readable by the working account and `sudo` is password-gated, so
the G12 journal state, the G12 evidence files and the G11 journal could not be
read directly in this session. What can be stated:

- **Structural:** `TRANSACTION_ROOT` has one definition and it is
  `/root/kyri-gen12-transaction`. No executable line references the
  Generation-11 journal. The Generation-12 transaction cannot write it.
- **Gated:** `--verify-installed` requires `journal_state` = `COMMITTED`
  (line 1460), the presence of `GEN12_LIBRARY_EVIDENCE` and
  `GEN12_HELPER_EVIDENCE` (lines 1463–1466), and the presence of
  `BASELINE_LIBRARY_EVIDENCE` — the Generation-11 evidence (line 1467). It
  passed with no FAIL, so all four hold.
- **Corroborating:** `verify_unchanged_surface()` reads the Generation-11
  evidence file to check all 51 carry-over objects and to prove nothing was
  removed. It could not have passed had that evidence been lost, and its result
  agrees exactly with the independent file-by-file comparison above.

G12 journal **COMMITTED** and G11 evidence **preserved** therefore rest on the
installer's own gates plus source-structural proof, not on a direct read. The
Generation-11 *journal directory* specifically is preserved by construction but
was not directly observed. An operator can close that gap read-only with:

```bash
sudo cat /root/kyri-gen12-transaction/state
sudo ls -l /root/kyri-gen11-transaction /root/kyri-gen11-*-digests.txt /root/kyri-gen12-*-digests.txt
```

## 7. Generation-11 → Generation-12 installed delta

| Class | Count | Detail |
| --- | --- | --- |
| Objects replaced | 6 | `tools/capability/`: `cli.py`, `coordinator.py`, `evidence.py`, `fabric_evidence.py`, `invocation_identity.py`, `records.py` |
| Objects created | 13 | `tools/fabric/`: `eligibility.py`, `resources.py`, `trust_adapter.py`; `tools/trust/`: `__init__.py`, `errors.py`, `expiry.py`, `identifiers.py`, `lineage.py`, `models.py`, `query.py`, `scope.py`, `store.py`, `transitions.py` |
| Directories created | 1 | `/usr/lib/kyri/python/tools/trust` (`0755 root:root`) |
| Unchanged objects | 51 | byte-identical, verified individually |
| Excluded helpers | 5 | unchanged, deliberately not installed |
| Object count | 57 → 70 | +13 |
| Aggregate digest | `80f9dee2…07f5b` → `9cbfd043…33830` | |

Accounting closes with no unexplained pathname.

## 8. Installer reporting defect — analysis

The live host is a whole Generation 12 while the installer announced
Generation 11. Every suspicious line was traced to its source. **Every one is a
stale operator-facing string. None is driven by incorrect generation-state
logic.**

| Message | Source | Class | Why |
| --- | --- | --- | --- |
| `19 CREATE operations` | L1386 | **B** | the count `matrix_count()`=19 is right; the word `CREATE` is hardcoded in the format string while the matrix is 6 REPLACE + 13 CREATE. The disposition is misreported, the number is not. |
| `COMMIT complete: 19 objects created and verified` | L998 | **B** | `published_n = matrix_count()` restates the matrix rather than counting publications, and `created` is hardcoded. Safe because the publish loop (L937–982) renames, then verifies digest, mode and `root:root` per row and rolls back on any mismatch — reaching this line is only possible if all 19 verified. Independently confirmed: all 19 at target hashes. |
| `Generation-11 evidence written; Generation-11 evidence preserved` | L1187 | **B** | the block writes `GEN12_LIBRARY_EVIDENCE` and `GEN12_HELPER_EVIDENCE` (`/root/kyri-gen12-*-digests.txt`, L90–91). Behaviour is right; the sentence names the wrong generation twice, and the first clause is the more misleading of the two. |
| `all 19 installed Generation-11 objects correspond to reviewed commit` | L1228 | **B** | the loop above it compares each target against field 5 — the **Generation-12** target hash. Correct check, wrong label. |
| `every Generation-11 runtime object is exactly its accepted baseline` | L1293 | **A** | this one is nearly true: the check skips matrix targets (`is_target … continue`) and compares only the 51 carry-over objects against the Generation-11 evidence, which *is* what they are. It reads as a claim about the whole runtime. |
| `the installed library holds N objects, expected the Generation-11 70` | L1226 | **A** | compares against `EXPECTED_LIBRARY_FILES_TARGET`=70; only the adjective is stale. |
| Final banners | L1494, L1496 | **B** | `Generation 11` is hardcoded in the `printf`. This is the most consequential line, because it is the one an operator reads last. |

Supporting evidence that the logic is generation-relational and sound:

- `classify()` returns `BASELINE` / `TARGET` / `UNKNOWN` — no generation numbers.
- `EXPECTED_LIBRARY_FILES_BASELINE=57`, `EXPECTED_LIBRARY_FILES_TARGET=70`.
- `matrix_count_of()` (L293) already computes per-operation counts correctly and
  is used at L887, which is why `PREPARE` reported `19 staged … 13 reserved`
  correctly. The correct helper exists and the other messages simply do not
  call it.
- L1360 — `Generation 12 / … verify: already installed` — is the one banner that
  names the right generation, showing the vocabulary is inconsistent rather than
  uniformly wrong.

**`INSTALLER_STATE_LOGIC_DEFECT = NO`.** No STOP was warranted and the installed
runtime is not invalidated.

### Severity

**Moderate — misleading, not destructive.** A stale comment at L1004–1007 also
now contradicts its own correct code, claiming "every target in this matrix is a
CREATE" and that the REPLACE branch "is never taken here"; L946 likewise says
"this transaction has nine".

An operator who read `Generation 11 / … install: all checks passed` could
reasonably conclude the installation did not take effect. The two actions that
belief invites are both non-destructive on the current host: a re-run of
`--install` reaches L1424 `Generation 12 is already installed: nothing to do`
and exits 0, and `--recover` against a COMMITTED journal with all targets at
TARGET settles without moving the generation. So no reachable operator response
damages the host — but the ceremony should not depend on that being true, and an
operator acting on a wrong belief about the installed generation is exactly the
confusion that produced defect A in the first place.

**`INSTALLER_REPORTING_DEFECT = YES`.** Per the checkpoint rules this is *not*
patched here. It requires its own RED-first checkpoint (§12).

## 9. Live G11-X proof — installed runtime

Exercised with `sys.path` sanitised to `/usr/lib/kyri/python`; no
`schott-platform` path was importable. Modules proved by `__file__`:

```
tools.capability.fabric_evidence      /usr/lib/kyri/python/tools/capability/fabric_evidence.py
tools.capability.invocation_identity  /usr/lib/kyri/python/tools/capability/invocation_identity.py
```

| Requirement | Result |
| --- | --- |
| Explicit operation required | `operation` is KEYWORD_ONLY; omitting it raises `TypeError: … missing 1 required keyword-only argument: 'operation'` |
| No operation default | `inspect` reports no default on `verify_selected_evidence` or `bind` |
| Unusable operation refuses | `None`, `""`, `"   "` → `operation-not-supplied` |
| Allowed `execute` passes | `supported=True`, `reason=None`, `operation='execute'` |
| Wrong operation refuses | `delete`, `administer`, `EXECUTE` → `operation-not-permitted-by-scope` |
| No silent normalisation | `"execute "` → refused `operation-not-supplied`; `_usable()` repairs nothing, so a non-canonical spelling never becomes a permitted one |
| Capability scope | `CAPDEF-9999` → `capability-not-permitted-by-scope` |
| Classification scope | `restricted` → `classification-not-permitted-by-scope` |
| Target/node scope | `HOST-9999` → `target-not-permitted-by-scope` |
| Operation in identity/evidence | `BINDING_FIELDS` includes `operation`; changing it changes the binding digest; verdict carries `operation` back |

Runtime-declared dimensions: `('permitted_capabilities', 'permitted_operations',
'permitted_data_classifications', 'permitted_targets')` — four, as designed.

**20/20 checks passed, exit 0.** No stage, no CINV allocation, no adapter, no
execve.

## 10. Live G11-Y proof — installed runtime

Driven through the invoke bridge over disposable fixture copies. Production
Fabric and Trust were never opened for writing.

```
tools.capability.fabric_evidence  /usr/lib/kyri/python/tools/capability/fabric_evidence.py
tools.fabric.eligibility          /usr/lib/kyri/python/tools/fabric/eligibility.py
ELIG conditions: ELIG-1 … ELIG-12
```

| Requirement | Result |
| --- | --- |
| Current eligible binding supported | `supported=True`, no reasons |
| R17 tail — advertisement stale, admission still open | refused, `('advertisement-not-fresh',)` |
| Revoked standing | refused, `('trust-revoked',)` |
| Unreadable/unknown standing | refused, `('trust-unreadable',)` |
| Host quarantined | refused, `('trust-not-usable', 'host-quarantined')` |
| Package quarantined | refused, `('trust-not-usable', 'package-quarantined')` |
| Host availability changed | refused, `('candidate-manually-drained',)` |
| Route movement alone | **still supported** — `route_version` 2 → 7 does not refuse |
| Route moved *and* host drained | refused on the current fact, not the route |
| Admission window expired (control) | refused, `admission-window-not-open` |

The last two together are the point: route movement alone does not invalidate a
historical `CSEL`, and the binding still refuses when a genuinely current fact
turns against it — so the first result is not merely "the route is never read".

**12/12 checks passed, exit 0.**

One methodological note: an initial fixture expressed quarantine as a Fabric
host field, which the runtime correctly ignored. Quarantine is Trust-plane
standing (`TrustState.QUARANTINED`, ELIG-10/ELIG-11). The fixture was corrected
to drive the real mechanism; the runtime was not at fault.

## 11. Production authority — no-change proof

Re-taken after installation and after both live proofs, against the fingerprints
captured before the ceremony:

| Surface | Pre-install | Post-install | Verdict |
| --- | --- | --- | --- |
| Fabric store | 21 files, `bcb2559b…f15e` | 21 files, `bcb2559b…f15e` | unchanged |
| Trust store | 26 files, `cffd362c…bc39` | 26 files, `cffd362c…bc39` | unchanged |
| Evidence + Artifacts | 3 files, `1f58bad3…4f9c07` | 3 files, `1f58bad3…4f9c07` | unchanged |
| Privileged helpers | five digests | identical | unchanged |
| `/etc/sudoers.d/` | `README` only | `README` only | both grants absent |

Chain records, byte-identical:

| Record | Digest |
| --- | --- |
| CADV-000003 | `f2b48c2efbe6c1f547f538c6686b1dd0aa24fcbee664ac7ea08c6f5aa2e7116d` |
| CINST-000002 | `5cfcf01e778856889c6aaa0838f986a0c43878033b29da1fd198be3070e3f719` |
| CROUTE-0002 | `1a7ed01877751ef70c8c25012cd947b23be9aa9a9c8cc17dacb6e79eba343870` |
| CSEL-000001 | `e08a4df4ab758cb0d25609e3cc02b4adca7568ff464b312ac3a2c88b8bbe79bb` |

Sequences unchanged: advertisement=3, contract=1, definition=1, host=1,
instance=2, package=1, route=2, selection=1.

Chain state at `2026-08-29T08:43:28-05:00` (America/Chicago): CADV-000003
`valid_until 2026-08-30T16:19:19-05:00` (fresh); CINST-000002
`lifecycle_state: admitted`, `admitted_until 2026-08-30T16:19:19-05:00`, host
CHOST-0001, trust TREC-000001; CROUTE-0002 at `route_version: 2`; CSEL-000001
selects CINST-000002. CADV-000003 → CINST-000002 → CROUTE-0002 → CSEL-000001 is
intact and untouched.

No record was created, renewed or superseded. CSEL-000001 remains historical
evidence; no new CSEL was made merely because the runtime generation changed.

**Root Authority:** `/var/lib/kyri` is `drwx--x--x root:root` and is not a
separate mount. Unchanged.

## 12. Validation disposition

Per the checkpoint rules the repository validator was not rerun: G11-Z1 already
proved the committed source and the installation fixture at quick 78/78 and full
101/101, and no repository file changed in this checkpoint — the working tree was
clean throughout and HEAD did not move. `tools/dev/run-validation.sh` contains no
reference to `/usr/lib/kyri`, so it is fixture-based and could not have proved
anything about the actual host.

The live check that *is* probative was run instead: the declared import closure
resolved entirely from the installed runtime — 54 `tools.*` modules from the two
capability roots, **zero** loaded from outside `/usr/lib/kyri/python`, zero
external site-packages. The Trust package resolves under the installed tree.

## 13. Actions not performed

No stage. No invoke. No CINV allocation. No adapter enabled. No execve or worker
execution. No sudoers installed. No `--recover`. No journal read, written,
deleted or edited by this session. No manual runtime modification. No production
Fabric, Trust, Artifact or Evidence mutation. No new Fabric record. No fix
applied to the reporting defect. No repository file changed other than this
report.

## 14. Readiness for the first controlled production stage/invoke

The enforcement runtime is installed and proved live: G11-X operation authority
and G11-Y current eligibility both behave correctly when loaded from
`/usr/lib/kyri/python`. That was the objective of this checkpoint and it is met.

`STAGE_INVOKE_AUTHORISED = NO`. The first production stage/invoke remains a
separate reviewer-authorised ceremony.

Before it, the reviewer should weigh:

1. **The reporting defect (§8).** Recommended next checkpoint — a small
   RED-first correction pinning Generation-12 vocabulary and matrix disposition:
   a test asserting the operator-visible strings, then the fix. Minimum required
   output: `6 REPLACE`, `13 CREATE`, `19 total changed objects`,
   `Generation-12 evidence written`, `Generation-11 evidence preserved`,
   `Generation-12 installed objects verified`, and Generation-12 final banners
   for both `--install` and `--verify-installed`. `matrix_count_of()` already
   exists and is the natural instrument. The stale comments at L946 and
   L1004–1007 should be corrected in the same pass. This is a reporting-only
   change and must not touch transaction logic.
2. **The `/root` gap (§6).** Two read-only operator commands would convert the
   journal and evidence findings from gated to directly observed.

Carried forward unchanged, and deliberately not addressed here:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`
- Privileged-helper drift remains excluded and must not be silently installed.
