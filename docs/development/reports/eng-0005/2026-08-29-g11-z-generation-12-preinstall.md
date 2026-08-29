# ENG-0005 G11-Z — Generation 12 Runtime Closure, Packaging, and Pre-Install Verification

- Checkpoint: ENG-0005 G11-Z
- Date: 2026-08-29
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `1313df019472a73e139cfc294ee8e016ad1355c0`
- Host: `schai`
- Result: `ACCEPTED` (package prepared and verified; **not installed**)

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `1313df019472a73e139cfc294ee8e016ad1355c0` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-X `9300250` ancestor | yes |
| G11-Y `58d95ce` ancestor | yes |
| G11-X / G11-Y reports | both present |
| Governed chain | `CADV-000003 → CINST-000002 → CROUTE-0002 → CSEL-000001`, intact |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Root Authority | unmounted |
| Kyri sudoers rules | 0 |

Manifests captured before any work:

| Authority | Files | Digest |
|---|---|---|
| Installed runtime (`/usr/lib/kyri/python`, `*.py`) | 57 | `80f9dee2…07b5f` |
| Fabric | 21 | `bcb2559b…f15e` |
| Trust | 26 | `cffd362c…bc39` |
| Artifact | 2 | `30732e2c…257f` |
| Platform Evidence | 1 | `227abde8…984b` |

## 2. Installed Generation-11 proof

```
/usr/lib/kyri/python : 57 .py objects
aggregate digest     : 80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

Matches the accepted installed state exactly. The 57 objects are: 4 flattened
privileged helpers, `tools/__init__.py`, 5 `tools/common`, 9 `tools/fabric`
(Generation 11's closure), and 38 `tools/capability`.

## 3. Reconstructed generation packaging architecture

Read from `install-generation-11.sh`, `install-generation-10.sh`,
`generation-11-surface.sh`, and the Generation-11 installer suite.

| Element | How it works |
|---|---|
| Installer | one transactional script per generation, `provisioning/execution/install-generation-N.sh` |
| Reviewed authority | `COMMIT`, pinned; must be present and an ancestor of HEAD; the working tree is never the input |
| Object matrix | `source\|destination\|mode\|op\|baseline_digest\|target_digest`, pinned both ways |
| Baseline gate | the installed set must equal the predecessor's root-owned evidence at `/root/kyri-genN-*-digests.txt` |
| Produced evidence | a successful install writes its own generation's digest record, mode `0400` |
| Journal | `NONE → PREPARING → PREPARED → COMMITTING → COMMITTED`, with `ROLLING_BACK`/`ROLLED_BACK` |
| Publication | prepared copies beside their targets, then `rename(2)`; same-filesystem gate first |
| Package directory | created by property (owner, mode, no undeclared members), not by digest — a directory has no bytes to pin |
| Exclusions | modules that must **not** be installed, asserted absent on every run |
| Closure gate | the matrix must be exactly the import closure, minus what is already installed |
| Modes | `--verify`, `--install`, `--verify-installed`, `--recover` |
| Ownership | `0444` for runtime objects, `root:root`; package directory `0755` |

Why each installed object belongs: `tools/capability/**` is the runtime itself;
`tools/common/**` and `tools/fabric/**` are what it imports; the four flattened
`kyri_exec_*.py` are executed by root through the library root rather than
through the package, so they are installed as top-level modules.

## 4. The actual runtime root set

Generation 11 computed its closure from **one** root, `tools.fabric.inspection`.
That was never the runtime's entry point — it was the entry point of the *gap*
Generation 11 was closing. The roots are the modules the installed runtime is
actually entered through:

| Root | Why it is one |
|---|---|
| `tools.capability.cli` | the operator interface: `invoke`, `inspect`, `validate`, `authorise-launch` |
| `tools.capability.execution.worker` | the far side of `execve`; entered by pathname, never imported by the CLI |
| `kyri_exec_transition` | the privileged transition, executed by root |
| `kyri_exec_transition_action` | its action half |
| `kyri_exec_verify` | the verification-only transition |
| `kyri_exec_quota` | the quota helper |

**The root set was validated, not asserted.** Computing the closure from these
roots over the Generation-11 commit yields 46 files, all of which are installed.
The remaining 11 installed objects are reachable from no root at all:

```
tools/capability/execution/{adapter,admin,cleanup,collector,image_store,
                            lifecycle,protocol,quarantine,quota,verification}.py
tools/common/yaml_strict.py
```

These are support modules earlier generations installed for their own entry
points — an admin ceremony whose flattened helper is not installed, the adapter
seam, the image store. They are **named explicitly** in the packaging test, so a
new unreachable module appearing is a decision somebody has to make rather than a
silent addition. The rule is therefore *reachable ⊆ packaged*, not
*reachable = packaged*.

## 5. RED proof that the Generation-11 surface is insufficient

Computed from the reviewed commit, before any packaging change. **Thirteen
modules are reachable from the runtime's roots and absent from the installed
surface**:

```
tools/fabric/eligibility.py
tools/fabric/resources.py
tools/fabric/trust_adapter.py
tools/trust/__init__.py
tools/trust/errors.py
tools/trust/expiry.py
tools/trust/identifiers.py
tools/trust/lineage.py
tools/trust/models.py
tools/trust/query.py
tools/trust/scope.py
tools/trust/store.py
tools/trust/transitions.py
```

This is structural and deterministic: it is the difference between an import
graph and a file list, not an inference from a commit message. Had Generation 12
not been built, those imports would have resolved on a production host only
because `/opt/schott-platform` happens to be on `sys.path` — precisely the defect
`generation-11-surface.sh` was written to close, reappearing one generation later
for a different reason.

**Two of the thirteen were deliberately excluded by Generation 11.**
`generation-11-surface.sh` states it installs the closure of
`tools.fabric.inspection` and that it "does NOT include `admission.py`, `cli.py`,
`selection.py`, `eligibility.py` or `trust_adapter.py`, and reaches nothing in
`tools.trust`." That was true when written. G11-Y made it false. The reasoning
still holds for the *write* path — `admission.py`, `selection.py`, and the Fabric
`cli.py` remain excluded — but eligibility is not a write path: it allocates
nothing, writes nothing, takes no lock, and the boundary hands it surfaces that
expose reads and nothing else.

The RED assertions are permanent (Part 1 of the packaging suite), so the reason
Generation 12 exists stays legible.

## 6. The computed Generation-12 closure

```
roots    : 6
modules  : 59 files reachable
packaged : 70 objects (57 installed ∪ 13 new)
external : ['yaml']   — the one third-party dependency, already present
```

The external set is reported rather than discarded: a new third-party dependency
is a packaging decision, and discovering it at import time on a production host
is the wrong place to have that conversation.

## 7. Closure algorithm and validation

The rule moved out of the installer into `tools/dev/runtime_closure.py`. One
implementation now answers the installer, the packaging test, and the soundness
test; Generation 11 kept it in a heredoc nothing else could read, which is why
it went stale silently.

Properties: deterministic and sorted; walks `ast` rather than importing, so no
module executes; follows relative imports by level; resolves `from x import y`
both as attribute and as submodule and keeps whichever exists; adds every package
`__init__` on the path to a member, because the import system runs them;
excludes the standard library; treats the flattened helpers by their installed
names; and reports unresolved in-namespace names instead of dropping them.

**Validated against a known answer.** Over the Generation-11 commit the closure
reproduces exactly the installed Fabric surface, and every one of its 46 files is
installed. That is what makes the same computation trustworthy at HEAD.

The installer's gate now also reads the baseline from the host's own library root
rather than from a hand-written `ALREADY_INSTALLED` list, so it cannot drift from
what is really installed — the failure mode that produced this checkpoint.

## 8. Generation-11 → Generation-12 object delta

| | Count |
|---|---|
| Generation-11 objects | 57 |
| Generation-12 objects | **70** |
| CREATE | 13 |
| REPLACE | 6 |
| UNCHANGED | 49 |
| REMOVED | **0** |

**CREATE (13)** — every one newly reachable, explained in §5:
`tools/fabric/{eligibility,resources,trust_adapter}.py`,
`tools/trust/{__init__,errors,expiry,identifiers,lineage,models,query,scope,store,transitions}.py`.

**REPLACE (6)** — the two corrections this generation exists to deploy:

| Object | Why |
|---|---|
| `tools/capability/fabric_evidence.py` | G11-X scope authority + G11-Y eligibility gate and the two read adapters |
| `tools/capability/coordinator.py` | threads `operation` and `trust_root` |
| `tools/capability/cli.py` | `--operation` and `--trust-store-root`, both required |
| `tools/capability/invocation_identity.py` | the operation joins the binding digest |
| `tools/capability/records.py` | the operation joins the closed `INVOCATION_FIELDS` |
| `tools/capability/evidence.py` | the durable `CINV` records the operation |

### 8.1 ⚠ Two objects deliberately NOT deployed

The delta computation initially produced **8** REPLACE rows.
`kyri_exec_transition.py` and `kyri_exec_transition_action.py` also differ from
repository source — but not because of G11-X or G11-Y. Their drift traces to
commits `16f285e` and `cfb0edd`, both **ancestors of the Generation-11
authority**, and was first recorded at G11-E as installed helpers lagging source.

The change is substantive and security-relevant: `worker_argv` gains a required
`worker_script` taken from the authenticated policy instead of the module's own
constant, and it is executed **by root**. It was never reviewed in this checkpoint
chain. Republishing it as a side effect of deploying an unrelated correction is
exactly the quiet widening this ceremony exists to prevent, so both are excluded
by name and stay at their reviewed installed bytes.

**Consequence, stated plainly**: after Generation 12, 68 of 70 installed objects
will match HEAD exactly; those 2 will remain at their Generation-11 bytes. The
drift stays open as its own item.

## 9. Source digest authority

The matrix pins both ends of every row: the baseline digest is what is installed
now, the target digest is the reviewed commit's blob. `--verify-source` proves all
19 changed objects match the reviewed commit:

```
ok  19 Generation-12 source objects match the reviewed commit 1313df01…
```

Reviewed authority: `1313df019472a73e139cfc294ee8e016ad1355c0`, the commit
containing both G11-X and G11-Y. It is present and an ancestor of HEAD, and the
working tree is never the input — a ceremony runs from reviewed bytes only.

## 10. Installer and preflight design

`provisioning/execution/install-generation-12.sh`, derived from the Generation-11
pattern with the transaction machinery intact: journal, prepared copies,
`rename(2)` publication, same-filesystem gate, rollback, recovery, foreign-object
gate, exclusion gate, and post-install digest verification.

Changed for this generation:

- `COMMIT` → `1313df01…`; baseline `GEN11_COMMIT` → `6016d4f0…`
- counts `BASELINE=57 → TARGET=70`
- `PACKAGE_DIR` → `tools/trust` (`tools/fabric` already exists from Generation 11)
- `EXCLUDED` rewritten: `eligibility.py`/`trust_adapter.py` leave it; the Fabric
  write path stays; the whole Trust **decision** surface joins it —
  `evaluator`, `root_authority`, `gateway`, `policy`, `audit`, `cli`
- closure gate → the shared utility, six roots, baseline read from the host
- **`--verify-source` added**

`--verify-source` is new because every Generation-11 mode reasoned about the
host, and the question an operator has *before* installing is whether the package
is sound. It touches no installed path. It proves repository authority, the 19
pinned source digests, the closure, and — by grepping the reviewed blob — that
the G11-X refusal vocabulary and the G11-Y elements are actually present:

```
ok  repository at arch/eng-0005-execution-transition, reviewed authority … an ancestor of HEAD
ok  19 Generation-12 source objects match the reviewed commit …
ok  the import closure of tools.capability.cli tools.capability.execution.worker
    kyri_exec_transition kyri_exec_transition_action kyri_exec_verify kyri_exec_quota
    closes over the declared surface (59 modules)
ok  the reviewed source carries the G11-X per-invocation operation and scope authority
ok  the reviewed source carries the G11-Y current-eligibility revalidation
note no installed path was read for state and none was written

Generation 12 source verification: all checks passed. 19 object(s) would change.
```

Exit 0. Nothing was weakened to make it pass: the Generation-11 gates are all
still present and all still run.

**`--verify` (host readiness) was not run to completion.** It reads the
root-owned Generation-11 evidence at `/root/kyri-gen11-*-digests.txt`, and this
session cannot become root non-interactively. It failed closed at exactly that
point, having passed every gate before it. That is an operator step, listed in
§16. The host's Generation-11 state was proved independently in §2.

### 10.1 A defect the derivation introduced, found and fixed

Deriving from Generation 11 left the evidence this transaction *produces*
pointing at the same root-owned file as the baseline it *consumes*. A successful
install would have written Generation-12 digests over the Generation-11 record it
had just verified against — destroying both the account of what was replaced and
the only file a rollback could be checked against. Produced evidence is now
`/root/kyri-gen12-*-digests.txt`. Committed separately as `4d01d75`.

## 11. Isolated runtime import proof

The package is materialised from the reviewed commit into a temporary root and
imported with the repository removed from `sys.path` entirely, from `cwd=/`, with
a sanitised environment.

```
PASS: the isolated runtime holds 70 objects (got 70)
PASS: the isolated runtime imports cleanly
PASS: every probed module imported (12/12)
PASS: every module resolved from the isolated package ([])
PASS: the repository was not on sys.path ([])
```

Probed: `tools.capability.cli`, `.coordinator`, `.fabric_evidence`,
`tools.fabric.eligibility`, `.trust_adapter`, `.resources`, `tools.trust.store`,
`.query`, `.scope`, and `tools.capability.execution.{authorisation,launch,worker}`.

The strays check compares each module's `__file__` against the isolated root.
This is the assertion that matters: a closure can look complete on paper while
every import silently falls back to `/opt/schott-platform`, and that is the
failure Generation 11 shipped.

## 12. Isolated G11-X / G11-Y behavioural proof

The code under test is imported **from the package**, not from repository source
— confirmed by `inspect.getsourcefile` pointing inside the isolated root.

```
PASS: the code under test came from the package (/tmp/…/lib/tools/capability/fabric_evidence.py)
PASS: G11-X: the packaged boundary requires an operation with no default
PASS: G11-X: the operation is bound to the invocation digest and the record
PASS: the packaged coordinator threads both new inputs
PASS: G11-Y: the packaged boundary requires a trust root with no default
PASS: G11-Y: the packaged boundary calls the released eligibility engine
PASS: G11-Y: the packaged fabric reader is exactly two reads
PASS: G11-Y: the packaged trust reader is exactly two reads
PASS: G11-X: the packaged boundary refuses an absent operation (operation-not-supplied)
```

The last is a live refusal from the packaged code, reached before any record is
read — which is why it needs no fixture.

Deeper behavioural cases (R17 tail, revoked and quarantined standing, moved
route) are covered against source by `test-capability-invoke-current-eligibility.sh`,
which passes. What the isolated run adds is that the *package* carries the same
code, which is the question packaging can get wrong.

## 13. Verification totals

| Suite | Result |
|---|---|
| `test-capability-execution-generation12-packaging.sh` (new) | PASS |
| `test-capability-invocation-operation-authority.sh` | PASS |
| `test-capability-invoke-current-eligibility.sh` | PASS |
| `test-capability-execution-generation11-installer.sh` | PASS |
| `test-capability-execution-g5-preflight.sh` | PASS |
| `test-fabric-runtime-install-closure.sh` | PASS |
| `test-capability-runtime.sh` | PASS |
| `test-capability-fabric.sh` | PASS |
| `test-platform-model.sh` | PASS |
| `pre-commit run --all-files` | PASS |
| `install-generation-12.sh --verify-source` | PASS (exit 0) |

### 13.1 A miss of my own, corrected

I first reported shellcheck clean on the strength of `shellcheck -S warning`. The
repository's pinned pre-commit hook runs at **info** severity and rejected four
findings — two `A && B || C` constructs that are not if-then-else, and two
unquoted expansions relying on word splitting. The first commit therefore did not
satisfy the repository gate. Fixed and committed separately as `e56eb5c`; the
correct check is the hook, not a looser invocation of the same tool.

## 14. Quick and full validation

| Mode | Result |
|---|---|
| `run-validation.sh --quick` | **passed, 77/77 steps** |
| `run-validation.sh` (full) | **passed, 100/100 steps** |

Both totals re-measured: quick 76 → 77, full 99 → 100, because the new packaging
suite runs in both modes. Registered in `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`.

**Completion method**: each validator was launched with its PID captured, waited
on with `kill -0 "$PID"`, and judged by its own exit status and output file. No
self-matching `pgrep -f 'run-validation.sh'` was used — that pattern matches the
polling shell itself and produced a false "RUNNING" reading at G11-X.

## 15. Production no-mutation proof

```
installed runtime digest : 80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b (unchanged)
installed object count   : 57 (unchanged)
Fabric manifest          : IDENTICAL
Trust / Artifact / Evidence : IDENTICAL
current-generation marker: untouched
sudo install invoked     : never
Kyri sudoers rules       : 0
CSEL count               : 1
handoff entries          : 0
```

The packaging suite carries its own guard and reports both `no production path
changed while this suite ran` and `the installed runtime was not modified`.
Nothing was staged or invoked.

## 16. The privileged installation command expected next

Not authorised in this checkpoint. When it is, the operator sequence is:

```bash
cd /opt/schott-platform

# 1. package soundness, no privilege, touches no installed path
bash provisioning/execution/install-generation-12.sh --verify-source

# 2. host readiness — needs root, reads /root/kyri-gen11-*-digests.txt
sudo bash provisioning/execution/install-generation-12.sh --verify

# 3. the transaction
sudo bash provisioning/execution/install-generation-12.sh --install

# 4. audit the result
sudo bash provisioning/execution/install-generation-12.sh --verify-installed
```

Expected after step 3: 70 objects, `tools/trust/` created `0755 root:root`, ten
Trust modules and three Fabric modules at `0444`, six replaced capability
modules, and `/root/kyri-gen12-*-digests.txt` written `0400`.

Step 2 is the one this session could not perform, and it must pass before step 3.

## 17. Rollback and recovery

Preserved from the Generation-11 pattern, unchanged:

- **Interrupted PREPARE** — nothing published; the exit trap unwinds staged
  material, removes the package directory if this transaction created it and it
  is empty, and removes the journal, returning the host to no-transaction.
- **Interrupted COMMIT** — the journal records `COMMITTING`; `--recover` either
  completes forward from prepared material or rolls back to the retained
  Generation-11 copies.
- **Rollback** — REPLACE rows restore from `.kyri-gen12.gen11` backups; CREATE
  rows are removed by fenced removal; the package directory is removed if this
  transaction created it.
- **Baseline record** — `/root/kyri-gen11-*-digests.txt` survives the install
  (§10.1) and is what a rollback is checked against.

Manual fallback if the transaction is unrecoverable: the host remains at
Generation 11, which is a complete and self-consistent runtime — it simply lacks
the G11-X and G11-Y enforcement, which is the state it is in today.

## 18. Outstanding, and deliberately separate

| Item | Status |
|---|---|
| `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING` | **YES** — not touched |
| `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING` | **YES** — not implemented |
| `ELIG6_ADVERTISEMENT_HEAD_POLICY` | **UNRESOLVED** — semantics unchanged |
| Privileged-helper drift (§8.1) | open; needs its own review, not a side effect |
| Artifact authority digest discrepancy vs G11-A/B/C | still unresolved |

## 19. Readiness decision

**The package is ready to install; the installation is not authorised here.**

What is proved: the closure is complete from the real roots and validated against
a known answer; the surface closes the graph with nothing surplus; the decision
surfaces are neither packaged nor reachable; a runtime built from the package
alone imports with the repository off `sys.path`; and that runtime carries the
G11-X and G11-Y behaviour. `--verify-source` passes.

What is not: `--verify` against the live host, which needs root and is step 2 of
§16. Until Generation 12 is installed and audited, production enforcement still
lacks per-invocation operation authority, four-dimension scope checks, and
invoke-time current eligibility — so no production invoke is authorised.

`INSTALL_READY = YES`, conditional on step 2 passing.

## Appendix A — commands executed

```bash
# Preflight and manifests (read-only)
git rev-parse HEAD; git status --porcelain
git merge-base --is-ancestor 9300250 HEAD; git merge-base --is-ancestor 58d95ce HEAD
( cd /usr/lib/kyri/python && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum )

# Root derivation, validated against the Generation-11 answer
git archive --format=tar <gen11 commit> tools provisioning/execution | tar -x -C <tmp>
python3 tools/dev/runtime_closure.py --source-root <tmp> --root … --format files

# RED: the same computation at HEAD, differenced against the installed surface
python3 tools/dev/runtime_closure.py --source-root <head tree> --root … --format files

# Package, tests, and read-only verification
bash tests/test-capability-execution-generation12-packaging.sh
bash provisioning/execution/install-generation-12.sh --verify-source     # exit 0
bash provisioning/execution/install-generation-12.sh --verify            # needs root
pre-commit run --all-files

# Validators, waited on by captured PID and judged by exit status
bash tools/dev/run-validation.sh --quick & QUICK=$!   # 77/77
while kill -0 "$QUICK" 2>/dev/null; do sleep 20; done
bash tools/dev/run-validation.sh & FULL=$!            # 100/100
while kill -0 "$FULL" 2>/dev/null; do sleep 30; done
```

## Appendix B — the generation, stated once

```
GENERATION 11 (installed)         57 objects   80f9dee2…07b5f
  closure root: tools.fabric.inspection            ← never the runtime's entry point
  excluded: admission, cli, eligibility, selection, trust_adapter
  reaches nothing in tools.trust                   ← true when written; false since G11-Y

GENERATION 12 (prepared, not installed)   70 objects
  roots: tools.capability.cli, tools.capability.execution.worker,
         kyri_exec_transition, kyri_exec_transition_action,
         kyri_exec_verify, kyri_exec_quota
  +13 CREATE   fabric{eligibility,resources,trust_adapter} + tools.trust read path
   +6 REPLACE  the G11-X and G11-Y capability modules
    0 REMOVED
  excluded: fabric{admission,cli,selection} + the whole Trust decision surface
  deliberately not deployed: kyri_exec_transition, kyri_exec_transition_action
```
