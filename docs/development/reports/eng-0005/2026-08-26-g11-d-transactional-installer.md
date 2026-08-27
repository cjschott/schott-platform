# ENG-0005 G11-D — Generation-11 Transactional Installer and Installation Rehearsal

**Date:** 2026-08-26
**Checkpoint:** G11-D
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Construct and prove the installation mechanism for the
already-reviewed Generation-11 source surface. G11-B pinned the nine-file
closure and deliberately stopped short of the installer; the accepted reviewer
ruling deferred that machinery to the ceremony that runs it. This is that
machinery.

**Outcome: READY_FOR_OPERATOR_INSTALL.**

The Generation-11 installer exists, is transactional, and is proven against
isolated fixture roots across **122 assertions** — clean installation, every
refusal the brief named, failure injection at **eighteen** distinct boundaries,
recovery in both directions from three mixed shapes, and the behavioural proof
that the installed closure actually satisfies the runtime with the repository
unreachable.

The G11-B closure was **independently re-derived twice** — once by AST walk over
the reviewed commit's blobs, once by observing what CPython actually loads — and
both agree exactly with the reviewed nine. `admission.py`, `selection.py` and
`cli.py` remain outside it, proven from imports rather than taken from the
report.

**One architectural carry-forward could not be made verbatim, and that is the
most important finding in this checkpoint.** Generation 10 proved its matrix
closed with a git source diff. Carried forward unchanged that gate is wrong in
*both* directions: it would miss seven of the nine objects Generation 11 must
install and admit sixteen it must not, including `admission.py` and the whole of
`tools/trust`. The gate was re-derived as a closure computation (§8.3). §6 gives
the measurement.

**Three defects were found by rehearsing rather than by reasoning** (§13), each
of which would have damaged a real installation or a real host.

**Generation 11 was NOT installed.** Production remains Generation 10:
`CGEN-000000000001`, 48 objects, no `tools/fabric`. Fabric, Trust and Platform
Evidence authority byte-identical. Full validator **94/94** from the clean
implementation commit.

**One unresolved discrepancy is reported rather than smoothed over** (§18): the
Artifact authority digest recorded in the G11-A/B/C reports cannot be reproduced
by any method that reproduces the other three. No mutation occurred — the
evidence for that is in §17 — but the recorded value and the observable one
disagree, and the reviewer should know.

---

## 2. Starting authority

| Gate | Observed | |
|---|---|---|
| Repository | `/opt/schott-platform` | PASS |
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD at start | `5f9347b6229f79dc6a5824ac6847cefbfcc0bf98` | PASS |
| Worktree | clean | PASS |
| G11-A implementation `18abf0f` ancestor of HEAD | yes | PASS |
| G11-B implementation `e9e6405` ancestor of HEAD | yes | PASS |
| G11-B report `16532ae` ancestor of HEAD | yes | PASS |
| G11-C implementation `6016d4f` ancestor of HEAD | yes | PASS |
| G11-C report `5f9347b` ancestor of HEAD | yes (is HEAD) | PASS |
| Installed generation | `CGEN-000000000001`, digest `fc9a3ec3…0163` | PASS |
| Installed objects | 48 | PASS |
| `tools/fabric` installed | **NO** | PASS |
| CADV / CINST / CROUTE / CSEL | 1 / 0 / 0 / 0 | PASS |
| `CADV-000001` | `cb2e16c7…e195` — unchanged from G11-C | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
```

Three of the four whole-tree authority digests reproduce the G11-C values
exactly. The Artifact digest does not, and §18 records why that is a reporting
discrepancy rather than a mutation.

### Digest method, stated so it can be reproduced

The method that reproduces the prior reports is **relative-path**:

```bash
( cd <root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )
```

An absolute-path walk of the same bytes gives a different answer
(`d23f286a…` for Fabric), because the pathnames are inside the hashed lines.
Recorded here because two checkpoints comparing whole-tree digests computed
differently would report a mutation that did not happen.

---

## 3. Authoritative material reviewed

| Object | What it settled |
|---|---|
| `docs/development/reports/eng-0005/2026-08-26-g11-a-instance-and-cadv-integrity.md` | the G11-A corrections carried by `models.py` |
| `…/2026-08-26-g11-b-runtime-dependency-closure.md` | the nine-file closure, the exclusions, the 48→57 count |
| `…/2026-08-26-g11-c-selection-preflight.md` | that G11-C did not widen the closure |
| `provisioning/execution/generation-11-surface.sh` | the reviewed matrix, digests and publication order |
| `provisioning/execution/install-generation-10.sh` | the transactional precedent, 1072 lines |
| `tests/test-capability-execution-generation10-installer.sh` | the test precedent |
| `tests/test-fabric-runtime-install-closure.sh` | the installed-only closure proof |
| `tools/capability/execution/implementation_authority.py` | that CGEN is a governed authority, not a library generation |
| `tools/provisioning/authority_admission.py` | that `current-generation` moves at admission |
| `tools/dev/run-validation.sh`, `.github/workflows/ci.yml` | registration convention |

---

## 4. Generation-10 installed baseline

`LIBRARY_ROOT=/usr/lib/kyri/python`, all objects `root:root`, files `0444`,
directories `0755`.

```
48 Python objects
directories: /usr/lib/kyri/python
             /usr/lib/kyri/python/tools
             /usr/lib/kyri/python/tools/capability
             /usr/lib/kyri/python/tools/capability/execution
             /usr/lib/kyri/python/tools/common
tools/fabric : ABSENT
```

The installed tree also carries `__pycache__` directories under the library
root, `tools`, `tools/capability` and `tools/capability/execution`. They matter
— see §13.2.

**`tools/fabric` exists in the *source* at the Generation-10 authority and has
since long before it.** It was never *installed*. That distinction is what makes
the delta a closure rather than a diff, and §6 turns it into a measurement.

---

## 5. Independently re-derived G11 closure

**Not copied from the G11-B report.** Derived twice, by two different means,
from the source rather than from the matrix.

### 5.1 Static — AST walk of the reviewed commit's blobs

Transitive closure of `tools.fabric.inspection`, following every `import` and
`from … import` (including relative levels, and treating `from x import y` as a
possible submodule reference), then adding every package initialiser the import
system executes on the way:

```
tools/__init__.py                    tools/fabric/identifiers.py
tools/common/__init__.py             tools/fabric/inspection.py
tools/common/immutable_store.py      tools/fabric/models.py
tools/fabric/__init__.py             tools/fabric/request_identity.py
tools/fabric/errors.py               tools/fabric/store.py
tools/fabric/evidence.py             tools/fabric/validator.py

closure size: 12
```

### 5.2 Runtime — what CPython actually loads

```
$ python3 -c "import tools.fabric.inspection; <list loaded tools modules>"
12 modules, identical set
```

Two independent methods, one answer. A static walk can over- or under-approximate
what an interpreter does; agreement between the two is what makes this a
derivation rather than a guess.

### 5.3 Subtraction, and the verdict

Generation 10 already installs three of the twelve — `tools/__init__.py`,
`tools/common/__init__.py`, `tools/common/immutable_store.py` — leaving **nine**.

```
tools.fabric.admission     in closure: False
tools.fabric.selection     in closure: False
tools.fabric.cli           in closure: False
tools.fabric.eligibility   in closure: False
tools.fabric.trust_adapter in closure: False
tools.trust.*              in closure: NONE
```

**The closure is unchanged from G11-B. It did not widen.**

### 5.4 The G11-C import, checked specifically

The brief asked for this to be proven independently. G11-C made `selection.py`
import `admission`. Imports flow `selection → admission`, and neither is
reachable from `inspection`: the closure is computed **downward from
`inspection`**, so an edge between two modules that are both outside it cannot
enter it. The AST walk confirms this without being told — `admission` and
`selection` simply never appear in the frontier.

### 5.5 Pinned digests, re-verified against current source

All nine rows of `generation-11-surface.sh` match the working tree **and** the
reviewed commit `6016d4f` **and** `e9e6405`, byte for byte. No pinned digest
required updating.

---

## 6. The Generation-10 → Generation-11 delta matrix

Closed. Nine rows, every one a CREATE, plus one directory.

| # | Source | Installed path | G10 state | G11 digest | Op | Why it is in the installed runtime |
|---|---|---|---|---|---|---|
| — | — | `…/tools/fabric/` (directory, `0755`) | ABSENT | — | CREATE | the package the nine modules live in |
| 1 | `tools/fabric/__init__.py` | `…/tools/fabric/__init__.py` | ABSENT | `e761edea…f6230` | CREATE | executed by Python on any submodule import |
| 2 | `tools/fabric/errors.py` | `…/errors.py` | ABSENT | `ddc6a765…e954a` | CREATE | exception types raised by `store`, `validator`, `inspection` |
| 3 | `tools/fabric/identifiers.py` | `…/identifiers.py` | ABSENT | `e523096c…63226` | CREATE | identifier grammar `inspection` validates records against |
| 4 | `tools/fabric/models.py` | `…/models.py` | ABSENT | `c6e0ce6d…d657b` | CREATE | the record models `inspection` reports with; carries **G11-A1** |
| 5 | `tools/fabric/request_identity.py` | `…/request_identity.py` | ABSENT | `b0ff8b1d…c1267` | CREATE | required by `validator` |
| 6 | `tools/fabric/evidence.py` | `…/evidence.py` | ABSENT | `48abf37c…1be1` | CREATE | required by `validator` |
| 7 | `tools/fabric/store.py` | `…/store.py` | ABSENT | `beda03b7…a13a` | CREATE | the store `inspection` opens read-only |
| 8 | `tools/fabric/validator.py` | `…/validator.py` | ABSENT | `dfdc02ff…1acda` | CREATE | record validation `inspection` delegates to |
| 9 | `tools/fabric/inspection.py` | `…/inspection.py` | ABSENT | `a59d36b1…0ca4a` | CREATE | **the entry point** — the one symbol `tools/capability/fabric_evidence.py` imports |

**Object count 48 → 57. Not one Generation-10 object is named**, so none can be
altered; the transaction can only add.

### 6.1 Why the delta is NOT a source diff — measured

The Generation-10 ceremony proved its matrix closed with:

```bash
git diff --name-only ${GEN9_COMMIT} ${COMMIT} -- 'tools/*.py'
```

Run between the Generation-10 and Generation-11 authorities, that produces
**eighteen** files:

```
tools/capability/execution/contract_outcome.py   tools/fabric/store.py
tools/capability/execution/result_content.py     tools/platform_model/evidence_fingerprint.py
tools/fabric/admission.py                        tools/platform_model/observe_host_architecture.py
tools/fabric/cli.py                              tools/platform_model/validate_evidence.py
tools/fabric/eligibility.py                      tools/trust/audit.py
tools/fabric/evidence_authority.py               tools/trust/cli.py
tools/fabric/models.py                           tools/trust/evaluator.py
tools/fabric/resources.py                        tools/trust/root_lineage_backfill.py
tools/fabric/selection.py                        tools/trust/store.py
```

Compared against the nine the closure requires:

- it **misses 7** of them — `__init__`, `errors`, `identifiers`,
  `request_identity`, `evidence`, `validator`, `inspection` — because those files
  did not *change* between the two authorities. What changed is that the
  installed runtime now needs them.
- it **admits 16** the closure does not require, **including `admission.py`,
  `cli.py`, `selection.py`, `eligibility.py` and the entire Trust plane** —
  precisely the mutation and control-plane surfaces this checkpoint must keep
  out.

Carrying the Generation-10 gate forward verbatim would have installed the
governed write path. The gate was therefore re-derived (§8.3), and the suite
asserts this divergence directly (assertion 7) so the reason cannot be lost:

```
PASS: the Generation-10 source-diff gate would miss 7 required objects and
      admit 16 it must not, including admission.py and the Trust plane
```

---

## 7. Excluded runtime surfaces, proven three ways

The brief asked for explicit exclusion tests. Each excluded surface is proven
absent by **three independent checks**, because a runtime that acquired the
mutation surface by accident would look exactly like one that acquired it on
purpose.

| Surface | Outside the computed closure | Outside the matrix | Absent from the installed tree |
|---|---|---|---|
| `tools.fabric.admission` | PASS | PASS | PASS |
| `tools.fabric.selection` | PASS | PASS | PASS |
| `tools.fabric.cli` | PASS | PASS | PASS |
| `tools.fabric.eligibility` | PASS | PASS | PASS |
| `tools.fabric.trust_adapter` | PASS | PASS | PASS |
| `tools.fabric.evidence_authority` | PASS | PASS | PASS |
| `tools.fabric.resources` | PASS | PASS | PASS |
| `tools.trust` (whole plane) | PASS | PASS | PASS |

`verify_excluded_absent()` runs in `--verify`, `--install` and
`--verify-installed`, and asserts over the **installed tree**, not over the
matrix — because the question is what the runtime can reach, not what the
ceremony intended.

The installed package is additionally asserted to be **exactly nine files**
(assertion 38). Not eight, not ten.

---

## 8. Installer architecture

**Path:** `provisioning/execution/install-generation-11.sh`, mode `0644`.

**Derivation of path and name.** `provisioning/execution/` holds
`install-generation-{5,6,7,8,9,10}.sh` — six precedents, one naming rule.
`tests/test-capability-execution-provisioning.sh` asserts nothing under
`provisioning/execution` is executable, and `install-generation-10.sh` is `0664`
while the newer `generation-11-surface.sh` is `0644`; `0644` matches the more
recent artifact and satisfies the rule. These artifacts are invoked deliberately
(`bash install-generation-11.sh --verify`), never by accident. The suite asserts
the absence of the execute bit (assertion 120).

**Modes:** `--verify`, `--install`, `--verify-installed`, `--recover`, plus
test-only `--fixture DIR`.

### 8.1 Pinned authorities

```
COMMIT       = 6016d4f0b8cfea9bfc8f60166b7cba5a2fa82a75   reviewed Generation-11 source
GEN10_COMMIT = 83da574bacde762de3222c60eb1873b2a750e54c   accepted Generation-10 authority
```

`6016d4f` is the commit at which all five G11 source blockers closed and at
which the reviewed nine carry the declared digests — verified, and identical at
`e9e6405` as well. It is pinned, never HEAD: a mutable reference is not an
authority. It is required to be an ancestor of HEAD and a descendant of the
Generation-10 authority.

### 8.2 What inverts against Generation 10

| | Generation 10 | Generation 11 |
|---|---|---|
| Operations | 4 REPLACE | **9 CREATE**, 0 REPLACE |
| Object count | 48 → 48 | **48 → 57** |
| New directory | none | **`tools/fabric/`** |
| Rollback material | retained predecessor bytes | **none — rollback is removal** |
| Delta gate | git source diff | **recomputed import closure** |
| Mixed-window hazard | coupled pair (`package_resolution`/`evidence`) | **none — every partial state fails closed** |

### 8.3 The closed-closure gate — the one genuinely new invariant

`require_closed_closure()` runs in `--verify` and `--install`. It extracts the
whole `tools` tree from the reviewed commit with a single `git archive` (as the
repository owner, never as root, and never from the working tree), walks the
imports, and requires:

```
matrix  ==  closure(tools.fabric.inspection)  −  already-installed
```

- a module that entered the closure since review → **refuses**
- a module in the matrix the closure does not require → **refuses**
- an excluded module appearing in either → **refuses, by name**

The whole tree is extracted rather than only the declared files deliberately: a
closure computed over the matrix could never discover that it needs a file
nobody declared.

### 8.4 The mixed window, measured rather than argued

Generation 10 documented an accepted coupled-pair window and did not pretend
ordering solved it. Generation 11 has no coupled pair — there is no predecessor
to be mixed with. Every intermediate state is an *incomplete package*, and every
incomplete package **fails closed**:

```
directory present, __init__.py absent, inspection.py absent
  import tools.fabric            -> OK (namespace package)
  import tools.fabric.inspection -> ModuleNotFoundError

directory present, __init__.py present, inspection.py absent
  import tools.fabric.inspection -> ModuleNotFoundError
```

Both orderings are therefore safe. **The reviewed publication order was
preserved unchanged** rather than re-decided — it is accepted authority, it is
not load-bearing for safety, and silently amending a reviewed declaration to
gain nothing would be the wrong trade. The suite asserts the closed failure at
three publication positions (assertions 80–82).

The caller that would observe the window, `tools/capability/fabric_evidence.py`,
cannot import at Generation 10 either, so **no intermediate state is a
regression on the baseline**.

### 8.5 Fenced removal

A CREATE's rollback is removal, and removal is the more dangerous verb. It is
fenced: a target is removed **only** when it is a regular file whose bytes are
exactly the object this transaction published. Absent, a symlink, a directory,
or bytes that are neither are **left exactly as found** for operator
disposition. A rollback that deleted unknown bytes would destroy the only
evidence of what happened.

The package directory is removed only when this transaction created it *and*
nothing else has moved in. Because an empty directory looks identical either
way afterwards, its provenance is recorded durably in the journal
(`package_dir_created=`) at the moment it is decided.

---

## 9. Transactional invariants carried forward

Every Generation-10 property, with its Generation-11 disposition. Derived from
the committed ceremony, not invented.

| Invariant | Carried | How |
|---|---|---|
| reviewed commit pinning | **yes** | `COMMIT` pinned; ancestor of HEAD; descendant of G10 authority |
| exact source digest verification | **yes** | every row re-derived from the commit object on every run |
| closed delta | **re-derived** | closure computation, not source diff (§6.1, §8.3) |
| exact installed-surface verification | **yes** | `verify_installed_set` + `verify_unchanged_surface` |
| baseline proof over the whole runtime | **yes** | G10 evidence checked both directions, 48 objects |
| prepared copies before any publication | **yes** | all nine staged and verified before the first rename |
| retained rollback material | **N/A** | a CREATE has no predecessor bytes; removal replaces it (§8.5) |
| trusted ownership verification | **yes** | `chown root:root` on prepared + post-publication `root:root` check |
| mode verification | **yes** | prepared and published both checked against `0444`; directory `0755` |
| no symlink traversal/substitution | **yes** | refused at target, at package directory, and on rollback |
| generation identity | **yes, and deliberately narrow** | library generation only; **CGEN untouched** (§9.1) |
| journal creation | **yes** | `NONE→PREPARING→PREPARED→COMMITTING→COMMITTED`, `ROLLING_BACK`/`ROLLED_BACK` |
| durable per-target progress | **yes** | nine `targetN=` rows plus `progress:` rows |
| recovery behaviour | **yes** | direction decided from provable material, never guessed |
| interrupted-install handling | **yes** | 18 injected boundaries; forward and back from 3 mixed shapes |
| atomic publication | **yes** | `rename(2)` per pathname; `fsync` of file and parent |
| refusal on unexpected existing state | **yes** | occupied target, foreign package object, residue |
| refusal on source drift | **yes** | pinned digest vs commit object |
| refusal on installed-state drift | **yes** | G10 baseline both directions; `--verify-installed` |
| refusal on unreviewed objects | **yes, strengthened** | the closure gate, plus foreign-object gate |
| post-install verification | **yes** | digests, modes, directory, count, exclusions, unchanged surface |
| previous-generation preservation | **yes** | G10 evidence never overwritten; new evidence under new names |
| git run as repository owner | **yes** | `runuser -u cschott` when not already the owner |
| no sudoers grant written; G3/G6.1B stay closed | **yes** | asserted structurally and behaviourally |
| authority namespace read-only | **yes** | fingerprinted before/after; write verbs asserted absent |

### 9.1 Generation identity — a distinction worth stating

`CGEN-000000000001` is the **governed implementation-authority generation**,
advanced by `tools/provisioning/authority_admission.py` when admission publishes
a CIMP record. The installer's "Generation 10 / 11" is the **runtime library
generation**. They are independent numbering schemes, and the Generation-10
ceremony touches the authority namespace only to read a fingerprint and prove it
did not move.

Generation 11 does the same. The suite asserts the ceremony contains no
reference to `current-generation` or `CGEN-` at all (assertion 110). **Installing
a library does not advance a governed authority.**

---

## 10. RED evidence

Established before any implementation, against the clean pre-checkpoint commit
`5f9347b`. Five assertions, and a proof that the failure is the missing
capability rather than a fixture or invocation defect:

```
RED  no Generation-11 installer exists at provisioning/execution/install-generation-11.sh
RED  no Generation-11 installer suite exists at
     tests/test-capability-execution-generation11-installer.sh
RED  the reviewed surface pins per-row digests but no reviewed commit object:
     there is no authority to materialise installed bytes FROM
RED  the reviewed surface performs no publication: no prepare, no journal,
     no rename, no recovery
RED  a governed Generation-11 installation cannot be attempted: the ceremony
     does not exist

--- attempted governed installation ---
bash: /opt/schott-platform/provisioning/execution/install-generation-11.sh:
      No such file or directory

have a writable fixture root: the refusal above is the installer's absence,
     not a fixture defect
have the reviewed matrix: 9 rows, 5 excluded

RED assertions: 5
```

The last two lines matter. The fixture is proven usable and the reviewed matrix
is proven present, so the missing thing is precisely the **mechanism** — not the
authority, and not the ability to run a test.

The permanent RED lives in the suite as assertion 50, which reproduces the
Generation-10 defect against a fixture rather than against production:

```
PASS: at Generation 10 the installed runtime cannot resolve tools.fabric
      without the checkout
      → ModuleNotFoundError: No module named 'tools.fabric'
```

---

## 11. Implementation

**Commit `ac60ec672f0986a671886507816dd6d224ed8db3`**
`feat(provisioning): add the Generation-11 transactional installer`

```
 .github/workflows/ci.yml                                     |    4 +
 provisioning/execution/install-generation-11.sh              | 1013 ++++++ (new)
 tests/test-capability-execution-generation11-installer.sh    | 1078 ++++++ (new)
 tools/dev/run-validation.sh                                  |   10 +-
```

**No runtime source changed.** G11-D adds an installation mechanism and its
proof; the nine modules it installs were already reviewed and already correct.

### 11.1 Why this is one commit

The brief asks for logically independent corrections in separate commits *when
that preserves a passing state*. It does not here. Registering a new suite moves
the validator's declared step totals (full 93→94, quick 73→74, both re-measured
rather than incremented, as the comment above them requires). Split out, the
installer commit would run every check, pass every one, and then **fail on its
own arithmetic** — a commit that cannot independently validate. The totals are
therefore in the same commit, and the commit message says so.

---

## 12. Complete test matrix

`tests/test-capability-execution-generation11-installer.sh` — **122 assertions,
all passing**, fixture-only, unprivileged.

The brief's eighteen cases, each mapped to evidence:

| # | Case | Disposition | Assertions |
|---|---|---|---|
| 1 | clean G10 → G11 rehearsal | **covered** | 9–14, 33–49 |
| 2 | exact reviewed source digests | **covered** | 5, 6, 31 |
| 3 | exact expected installed surface | **covered** | 34–39, 48, 56–61 |
| 4 | missing source object | **covered** | 32 |
| 5 | changed source bytes | **covered** | 31 |
| 6 | unexpected extra object | **covered** | 17, 22–24, 27, 60 |
| 7 | wrong ownership | **partial — see §12.1** | 106, 107 |
| 8 | wrong mode | **covered** | 37, 58, 59 |
| 9 | symlink substitution | **covered** | 25, 26, 101 |
| 10 | incorrect installed G10 baseline | **covered** | 15–18, 61 |
| 11 | interrupted preparation | **covered** | 62–66 |
| 12 | interrupted publication | **covered** | 67–79 |
| 13 | stale/incomplete journal | **covered** | 96, 97 |
| 14 | safe recovery | **covered** | 87–95, 98–102 |
| 15 | repeated verification | **covered** | 13, 14, 49, 54 |
| 16 | reinstall an established generation | **covered** | 53–55 |
| 17 | unreviewed module entering the closure | **covered** | 28, 29, 30, 60 |
| 18 | repository unavailable after staging | **re-scoped — see §12.2** | 103, 104, 105 |

### 12.1 Case 7 — ownership, stated honestly

This suite runs as uid 1000 and **cannot `chown`**, so a live wrong-owner case
is not constructible here. Manufacturing one would require privilege this
checkpoint must not take. What is constructible, and is asserted, is that the
discipline exists and cannot be bypassed:

- every prepared object is `chown root:root` before verification;
- the package directory is `chown root:root` on creation;
- every published target is re-checked `root:root` after its rename, with
  `OWNER_FAILED` recorded and a rollback triggered on mismatch;
- **the only guard on those branches is fixture mode**, so a production run
  cannot reach publication without them.

Recorded as a limitation rather than claimed as a pass. The live ownership path
is exercised for the first time during the operator ceremony.

### 12.2 Case 18 — re-scoped, with the reason

The brief conditions this case on "if the existing architecture requires this
property". **It does not, and that is deliberate rather than an omission.**

Every mode of the Generation-10 ceremony — including `--recover` — re-verifies
the pinned digests against the reviewed commit before acting. An unreachable
repository is therefore a **refusal, not a degraded mode**. Generation 11
carries that forward unchanged, and it is proven:

```
PASS: an unreachable repository refuses recovery and changes nothing:
      a refusal, not a degraded mode
```

The narrower property the architecture *does* require is proven directly:

```
PASS: every reviewed byte is materialised in PREPARE, before any publication
PASS: the publication phase consumes prepared bytes only: no repository read
      between COMMITTING and COMMITTED
```

Asserted structurally over the ceremony's own source, so a future edit that
introduced a `git` call into the publication path would fail the suite.

### 12.3 Failure injection — eighteen boundaries

Every boundary the transaction can be interrupted at, **cut rather than reasoned
about**. Before the commit point, all of these leave a *whole* Generation 10 —
no target, **no package directory**, no residue, 48 objects, G10 evidence
intact, no G11 evidence written:

```
directory  created  stage  staged  prepared  committing  publish  verify  precommit
1  2  3  4  5  6  7  8  9        ← the nine publication positions
```

After the commit point, Generation 11 **stands**:

```
PASS: a failure at 'postcommit' leaves generation 11 installed and committed
PASS: a failure at 'evidence'   leaves generation 11 installed and committed
PASS: a failure at 'cleanup'    leaves generation 11 installed and committed
PASS: --verify-installed accepts generation 11 after a cleanup failure
```

No failure in the bookkeeping after the durable commit point reverts the
generation — which is the property that stops a failed cleanup from inviting
somebody to "tidy up" a committed generation by reverting it.

---

## 13. Defects found by rehearsing rather than by reasoning

Three. Each would have damaged a real installation or a real host, and none was
predicted.

### 13.1 An interrupted PREPARE left the package directory behind

**Found by:** assertions 63–66 failing with `package-directory-survived`.

Generation 10 could leave prepared and retained copies behind after a failed
preparation, and did — its targets were REPLACE, every pathname already existed,
and the next run refused on residue. Generation 11 cannot be so relaxed, because
its litter includes a **`tools/fabric` directory**, and the accepted
Generation-10 installed surface is one in which that directory *does not exist*
(G11-B §3: *"tools/fabric is not present. It never was."*).

A halt during preparation would have left a host reporting itself at Generation
10 while carrying a pathname Generation 10 never had.

**Correction.** A `PREPARING` flag is set for the duration of preparation and
cleared at the durable `PREPARED` write. An `EXIT` trap unwinds on *every* exit
path — halt, injected failure, unexpected error — removing staged material and
the package directory if this transaction created it and it is empty. The
journal is **removed** rather than moved to a terminal state, because that is the
honest record: nothing was published, so the host has no transaction, and a
retry then starts cleanly instead of being refused as a rollback.

Once `PREPARED` is durable the flag is cleared, so the staged material becomes
the transaction's property and recovery may complete it forward.

### 13.2 The foreign-object gate rejected `__pycache__`

**Found by:** the import probe writing bytecode into a fixture, then
`--verify-installed` refusing it.

`require_no_foreign_package_objects()` rejected everything in the package
directory that was not a declared target. But the installed runtime **already
carries `__pycache__` under four directories** (§4), and CPython creates them the
first time it imports anything. A healthy Generation-11 production host would
have stopped verifying the moment it was first used.

**Correction.** Bytecode caches are exempt, with the reason recorded in the
source: they are the interpreter's, not the transaction's; every other installed
package on this host already carries one; and they are not an import surface —
CPython will not load a cached module whose source is absent in this layout, so
a stray `.pyc` cannot smuggle in a module. That question is answered by
`verify_excluded_absent()`, over the sources.

**This was found only because the suite runs the real runtime against the real
installed tree.** A digest-only test would have shipped it.

### 13.3 A bad matrix row ended the ceremony with no diagnostic

**Found by:** assertion 32 refusing, but silently.

```bash
blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
```

If the row names a path the reviewed commit does not carry, `git` fails,
`pipefail` fails the pipeline, and an assignment from a failed command
substitution ends the script under `set -e` — **before the `bad` message that was
supposed to explain it**. It failed closed, and told the operator nothing.

**Correction.** Existence is checked separately and first, so the operator is
told which row is wrong:

```
FAIL     tools/fabric/nonexistent.py is not present at the reviewed commit 6016d4f…
```

**The same latent shape exists in `install-generation-10.sh`** at its own
`require_source_digests`. It is unreachable there — every Generation-10 matrix
row exists at both pinned commits — and that ceremony is accepted, installed
authority. **It was not modified.** Reported here so the reviewer can decide
whether it is worth a separate correction; it is not a defect in anything
Generation 10 does.

### 13.4 One gate ordering, corrected for diagnostic quality

An undeclared module in the package directory was refused by the *baseline* gate
("the installed library holds 49 objects, expected 48") before the *foreign
object* gate could name it. Both refuse; the specific diagnostic should be the
one the operator reads, so `require_no_foreign_package_objects` now runs first.
Not a safety change — a legibility one, and the reasoning is in the source.

---

## 14. Failure and refusal proofs

Selected, from the 122. Each refuses **and** refuses for the right reason —
several assertions check the message, not just the exit status.

```
PASS: unrelated generation-10 runtime drift refuses the transaction
PASS: a runtime object the evidence records but the host lacks refuses
PASS: an unexpected runtime object refuses
PASS: missing generation-10 evidence refuses the transaction
PASS: an existing /etc/sudoers.d/kyri-exec refuses the transaction
PASS: an existing /etc/sudoers.d/kyri-exec-verify refuses the transaction
PASS: pre-existing transaction residue refuses
PASS: an occupied __init__.py pathname refuses: this transaction creates,
      it does not overwrite
PASS: a symlink substituted for a target refuses, and is left in place for disposition
PASS: a symlinked Fabric package directory refuses: no installation through a redirect
PASS: an undeclared module in the Fabric package directory refuses by name
PASS: an unreviewed Fabric module entering the closure refuses, naming the module
PASS: a module the closure does not require refuses even when it is not on the
      excluded list
PASS: a matrix missing a module the closure requires refuses, naming the module
PASS: a pinned digest that is not the reviewed commit object refuses
PASS: a matrix row whose source the reviewed commit does not carry refuses
```

The closure-gate cases are worth separating out, because they are what makes
"install only the reviewed closure" a check rather than a promise:

| Injected into a mutated ceremony copy | Refusal |
|---|---|
| `admission.py` added to the matrix | `EXCLUDED module tools/fabric/admission.py appears in the matrix` |
| `resources.py` added (not on the excluded list) | `the matrix declares tools/fabric/resources.py, which the closure does not require` |
| `validator.py` dropped from the matrix | `the closure requires tools/fabric/validator.py, which the matrix does not declare` |

The second is the important one: it refuses via the **closure computation**, not
via an excluded-list lookup. A ceremony that only consulted a denylist would
admit anything nobody thought to deny.

---

## 15. Interruption and recovery proofs

### Forward

```
PASS: recovery from 1-of-9 published completes FORWARD to a whole Generation 11
PASS: recovery from 4-of-9 published completes FORWARD to a whole Generation 11
PASS: recovery from 8-of-9 published completes FORWARD to a whole Generation 11
PASS: recovery from 1-of-9 states its direction as FORWARD   (also 4, 8)
```

### Backward

```
PASS: recovery from 1-of-9 with missing prepared material rolls BACK to a
      whole Generation 10                                     (also 4, 8)
```

Rolling back a CREATE transaction **removes** what landed and, because this
transaction created it, removes the package directory too — verified by object
count returning to 48 and the directory being gone.

### Refusals during recovery

```
PASS: unknown bytes halt recovery with 0 published, and are left exactly as found
PASS: unknown bytes halt recovery with 3 published, and are left exactly as found
PASS: unknown bytes halt recovery with 7 published, and are left exactly as found
PASS: a symlink substituted for a published target is refused and left in place,
      not unlinked
PASS: a package directory this transaction did not create survives rollback,
      while its targets are removed
PASS: a stale COMMITTED journal over absent targets halts for operator disposition
PASS: a journal with no state line recovers from the bytes on disk, not from
      the journal
```

The last two are the journal-trust boundary: **classification is always from
bytes, never from the journal.** A journal claiming COMMITTED over absent targets
does not get to be believed.

Interrupted fixtures are **constructed, not simulated** — the package directory
created, all nine staged, the first N genuinely renamed into place, and a durable
`COMMITTING` journal written. That is exactly what a crash mid-publication
leaves behind.

---

## 16. Rehearsal evidence

An isolated staging root reproducing Generation 10 exactly. Four steps, in the
order the operator ceremony will run them.

```
STAGING_ROOT=<scratchpad>/rehearsal
baseline objects: 48

===== STEP 1: --verify =====
ok  repository at arch/eng-0005-execution-transition, reviewed authority 6016d4f… present and an ancestor of HEAD
ok  9 Generation-11 source objects match the reviewed commit 6016d4f…
ok  the matrix is exactly the reviewed dependency closure: 12 modules reachable
    from tools.fabric.inspection, 3 already installed, 9 to install (9 CREATE, 0 REPLACE)
ok  all 5 deliberately excluded Fabric modules are outside the closure and outside the matrix
ok  the installed runtime is exactly the accepted Generation-10 baseline (48 objects)
ok  the Fabric package directory does not exist yet, as Generation 10 requires
ok  no transaction residue at any of the 9 target pathnames
ok  neither sudoers grant exists: G3 and G6.1B stay closed
ok  every target stages beside itself inside tools/fabric, so publication is a rename
ok  the governed write path, the operator input surface and the Trust plane are all
    absent from the installed runtime
ok  no transaction in progress
ok  the host is at Generation 10 and ready for the Generation-11 installation:
    9 CREATE operations (…), object count 48 -> 57
EXIT=0

===== STEP 2: --install =====
ok  PREPARE complete: 9 objects staged (…), 9 pathnames reserved,
    no rollback material required for a CREATE
ok  all 9 prepared objects verify against the reviewed commit
ok  COMMIT complete: 9 objects created and verified (…)
ok  Generation-11 evidence written; Generation-10 evidence preserved
ok  transaction artefacts removed
ok  all 9 installed Generation-11 objects correspond to the reviewed commit 6016d4f…
ok  the governed write path, the operator input surface and the Trust plane are all
    absent from the installed runtime
ok  every Generation-10 runtime object is exactly its accepted baseline, and
    nothing was removed
EXIT=0

===== STEP 3: --verify-installed =====
ok  all 9 installed Generation-11 objects correspond to the reviewed commit 6016d4f…
ok  the governed write path, the operator input surface and the Trust plane are all absent
ok  every Generation-10 runtime object is exactly its accepted baseline, and nothing was removed
ok  the Fabric package directory holds only declared objects
ok  neither sudoers grant exists: G3 and G6.1B stay closed
ok  no transaction artefacts remain
EXIT=0

===== STEP 4: --install again =====
ok  Generation 11 is already installed: nothing to do
EXIT=0

===== RESULT =====
objects: 57
tools/fabric/__init__.py          tools/fabric/models.py
tools/fabric/errors.py            tools/fabric/request_identity.py
tools/fabric/evidence.py          tools/fabric/store.py
tools/fabric/identifiers.py       tools/fabric/validator.py
tools/fabric/inspection.py
```

### The behavioural proof

Nine correct files is a digest claim. This is the one that matters:

```
PASS: at Generation 10 the installed runtime cannot resolve tools.fabric
      without the checkout
PASS: under the installed Generation 11 the runtime resolves Fabric with the
      repository unreachable
        tools.capability.fabric_evidence   IMPORT OK
        tools.capability.coordinator       IMPORT OK
        tools.capability.cli               IMPORT OK
        tools.fabric.inspection            IMPORT OK
PASS: no tools module resolved from outside the installed root
```

Run with `-E`, from `/`, with every `/opt` and `schott-platform` path filtered
out of `sys.path`. **The installed runtime stops borrowing a checkout.** That is
the defect G11-B identified, closed and demonstrated.

---

## 17. Production zero-mutation proof

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric | `7780dacf…ab072` | `7780dacf…ab072` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifact | `30732e2c…6257f` | `30732e2c…6257f` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |
| Installed generation | `CGEN-000000000001` | `CGEN-000000000001` | **UNCHANGED** |
| Installed objects | 48 | 48 | **UNCHANGED** |
| `tools/fabric` installed | NO | **NO** | **UNCHANGED** |

```
CADV-000001  cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195  UNCHANGED
CADV = 1   CINST = 0   CROUTE = 0   CSEL = 0
capability-selection.seq : absent
Root Authority : unmounted
/root/kyri-gen11-transaction : does not exist
```

`diff` of the before and after authority captures: **identical**.

The suite additionally snapshots thirteen production paths — including
`/usr/lib/kyri/python/tools/fabric`, `/var/lib/kyri`, `/data/kyri`,
`/mnt/kyri-root` and both sudoers grants — before and after every run:

```
PASS: no production path changed while this suite ran
PASS: production carries no installed Fabric package: Generation 11 is not installed
PASS: no fixture run wrote into the implementation-authority namespace
PASS: this suite runs unprivileged
```

**No privileged operation was performed at any point in this checkpoint.** No
`sudo`. No `runuser`. The whole checkpoint ran as uid 1000.

---

## 18. Unresolved: the Artifact authority digest

**Reported rather than smoothed over, and it is not a mutation.**

Three of the four whole-tree authority digests reproduce the G11-A/B/C recorded
values exactly. The Artifact digest does not:

```
recorded in G11-B and G11-C : 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
observed by every method tried: 30732e2c…  (relative, the method that reproduces the other three)
                                ef4297c6…  (absolute paths)
                                60b3966f…  (content only)
                                b8b0e8b4…  (path/size/mode)
                                abcfa6a9…  (/data/kyri/artifacts, a different root)
```

**Why this is not a production mutation:**

1. `/var/lib/kyri/artifacts` is `root:root 0755`; this checkpoint ran as uid
   1000 and a write probe was refused (`Permission denied`).
2. The authority holds **two files**, and both mtimes are **2026-08-24** — two
   days before this checkpoint, and before G11-A, G11-B and G11-C were written.
   Nothing has been written there since.
3. No read errors occurred during traversal, so the digest is over the complete
   tree.
4. The before/after capture within this checkpoint is **identical**.

The conclusion is that the value recorded in the earlier reports was computed
over a different root or by a different method, and I could not reconstruct
which. **The bytes have not moved.** Flagged so the reviewer can decide whether
the earlier records need a correction; it does not block this checkpoint, and
§17 proves the invariant that actually matters.

---

## 19. Validation

From the clean implementation commit `ac60ec6`, worktree clean.

| Check | Result |
|---|---|
| `git status --porcelain` | **clean** |
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh` | **PASS (full mode) — 94/94 steps** |
| `tools/dev/run-validation.sh --quick` | **PASS (quick mode) — 74/74 steps** |
| `tests/test-capability-execution-generation11-installer.sh` | **PASS — 122 assertions** |

```
Validation passed (full mode), started 2026-08-26T21:33:33-05:00, 94/94 steps.
```

**CI parity:** the new suite is registered in `tools/dev/run-validation.sh` and
in `.github/workflows/ci.yml`, and the suite asserts both registrations
(assertion 119).

### A validator defect, and how it was handled

Registering the suite exposed that the declared step totals are maintained by
hand. The first full run reported:

```
[94/93] Summary — all checks ran
FAILED: step count mismatch — declared 93, executed 94.
```

**This is not a pre-existing defect** — it is the direct and intended consequence
of adding a suite, and the validator behaved correctly by catching it. Both
totals were **re-measured in both modes** rather than incremented, as the comment
above them requires (the two modes do not always move together). It is not
buried: §11.1 explains why it is in the implementation commit rather than a
follow-up, and the commit message states it.

No pre-existing validator defect was discovered.

---

## 20. Actions explicitly NOT performed

- **Generation 11 not installed.** No production transaction opened, no object
  published, no production journal created.
- **No production installation command run.** See §21.
- **Generation 10 not modified.** Every row is a CREATE; no installed object is
  named.
- **No privileged operation.** No `sudo`, no `runuser`; the whole checkpoint ran
  as uid 1000.
- **No production generation state advanced.** `current-generation` untouched
  and unreferenced.
- **No Fabric, Trust, Artifact or Platform Evidence mutation.**
- **Root Authority not mounted.**
- **No `CADV-000002`, no CINST, no CROUTE, no CSEL.**
- **No runtime source changed.** The nine installed modules are byte-identical to
  the reviewed commit.
- **The runtime surface was not widened.** `admission.py`, `cli.py`,
  `selection.py`, `eligibility.py`, `trust_adapter.py`, `evidence_authority.py`,
  `resources.py` and `tools/trust` all remain out — proven three ways.
- **The reviewed publication order was not re-decided** (§8.4).
- **`install-generation-10.sh` was not modified**, despite the latent shape noted
  in §13.3 — it is accepted, installed authority and the shape is unreachable
  there.
- **No test was written that contradicts Generation-10 architecture.** Case 18
  was re-scoped with its reason stated (§12.2) rather than manufactured.
- **No ownership pass was claimed that could not be exercised** (§12.1).
- **No secrets recorded.**

---

## 21. The production installation ceremony — NOT RUN

The separately authorised operator ceremony is three commands, in this order.
Preconditions: the worktree clean, `HEAD` on `arch/eng-0005-execution-transition`
with `6016d4f` an ancestor, and the host at Generation 10.

```bash
# 1. read-only preflight — is the host at Generation 10 and ready?
sudo bash /opt/schott-platform/provisioning/execution/install-generation-11.sh --verify

# 2. THE TRANSACTION — nine CREATE operations, 48 -> 57
sudo bash /opt/schott-platform/provisioning/execution/install-generation-11.sh --install

# 3. read-only audit — is the host at Generation 11?
sudo bash /opt/schott-platform/provisioning/execution/install-generation-11.sh --verify-installed
```

If a run is interrupted:

```bash
sudo bash /opt/schott-platform/provisioning/execution/install-generation-11.sh --recover
```

**NONE OF THESE COMMANDS WAS RUN. `INSTALL_COMMAND_RUN=NO`.**

Root is required: step 1 reads the Generation-10 evidence under `/root`, and
steps 2 and 3 read it and write under `/usr/lib/kyri/python`. This checkpoint
stopped before that point, as instructed. **Step 1 was not run against production
either** — it needs root to read `/root/kyri-gen10-library-digests.txt`, and
running it unprivileged would report a missing baseline that is not missing.

After a successful installation, the reviewer should expect:

```
/usr/lib/kyri/python                        57 Python objects
/usr/lib/kyri/python/tools/fabric           root:root 0755, exactly 9 files at 0444
/root/kyri-gen11-library-digests.txt        0400, new
/root/kyri-gen11-helper-digests.txt         0400, new
/root/kyri-gen10-*-digests.txt              preserved, byte-identical
/root/kyri-gen11-transaction/journal        state=COMMITTED
current-generation                          CGEN-000000000001, UNCHANGED
```

And `tests/test-fabric-runtime-install-closure.sh` should then be re-run against
the **real** library root, as G11-C §17 recommends.

---

## 22. Questions requiring reviewer ruling

1. **Confirm the closure gate replacing the source-diff gate** (§6.1, §8.3). This
   is the largest deviation from Generation-10 precedent in this checkpoint, and
   §6.1 is the evidence that carrying the precedent forward verbatim would have
   installed `admission.py`, `cli.py`, `selection.py` and the Trust plane.
2. **Confirm `6016d4f` as the pinned reviewed Generation-11 authority.** It is
   the commit closing all five source blockers. The nine blobs are identical at
   `e9e6405`, so `e9e6405` would serve equally; `6016d4f` was chosen because the
   brief itself names it as establishing `G11_SOURCE_READY=YES`.
3. **Confirm that preparation now unwinds itself** (§13.1), including removing
   the journal rather than moving it to a terminal state. The alternative —
   Generation 10's behaviour — leaves a `tools/fabric` directory on a host that
   reports itself at Generation 10.
4. **Confirm the `__pycache__` exemption** (§13.2). It is required for a
   Generation-11 host to keep verifying after first use, and the argument that it
   is not an import surface should be checked rather than taken.
5. **Is the latent `set -e` shape in `install-generation-10.sh` worth a separate
   correction?** (§13.3.) It is unreachable there and that ceremony is installed
   authority, so it was left alone.
6. **Rule on the Artifact digest discrepancy** (§18) — specifically whether the
   G11-A/B/C recorded value should be corrected, given the bytes demonstrably
   have not moved.
7. **Confirm case 18 is correctly re-scoped** (§12.2): an unreachable repository
   is a refusal in every mode, and the property actually proven is that
   publication consumes prepared bytes only.

---

## 23. Recommended next checkpoint

**The Generation-11 production installation ceremony** — operator-authorised,
running the three commands in §21.

Then, in order:

1. **Re-run `tests/test-fabric-runtime-install-closure.sh` against the real
   library root**, proving the installed runtime is self-contained in
   production and not only in a fixture.
2. **`CADV-000002 supersedes CADV-000001`**, using the renewal path G11-A
   established. `CADV-000001` lapses at `2026-08-27T14:13:53-05:00`; nothing
   breaks, but a CINST needs a fresh claim.
3. **`CINST-000001`** — the first instance admission, with all five blockers
   closed.
4. **`CSEL-000001`** — the first governed selection, rehearsable before the
   identity is spent, per G11-C.

---

## Appendix A — commands executed

All read-only against production. Writes went to fixture roots and the
scratchpad only. **No `sudo` at any point.**

```bash
# Phase 0 — authority
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <each G11-A/B/C commit> HEAD
cat /var/lib/kyri/implementation-authority/current-generation
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )

# Phase 0 — independent closure derivation
python3 -c "<AST walk of tools.fabric.inspection over the working tree>"
python3 -c "import tools.fabric.inspection; <list loaded tools modules>"
source provisioning/execution/generation-11-surface.sh   # digests vs source
git cat-file blob 6016d4f:<each of the nine> | sha256sum
git cat-file blob e9e6405:<each of the nine> | sha256sum

# Phase 1 — the delta, and why it is not a diff
find /usr/lib/kyri/python -name '*.py' -not -path '*__pycache__*' | wc -l
git ls-tree -r --name-only 83da574 -- tools/__init__.py tools/capability tools/common
git diff --name-only 83da574 6016d4f -- 'tools/*.py'      # 18 files — see §6.1
python3 -E -c "<namespace-package behaviour for partial installs>"

# Phase 3 — RED
bash <scratchpad>/red-g11d.sh                              # 5 RED assertions

# Phase 4/5 — rehearsal
bash provisioning/execution/install-generation-11.sh --fixture <root> --verify
bash provisioning/execution/install-generation-11.sh --fixture <root> --install
bash provisioning/execution/install-generation-11.sh --fixture <root> --verify-installed
bash provisioning/execution/install-generation-11.sh --fixture <root> --install   # no-op
bash tests/test-capability-execution-generation11-installer.sh                    # 122 assertions

# Phase 6 — validation from the clean implementation commit
git diff --check ; tools/dev/run-shellcheck.sh
pre-commit run --all-files
tools/dev/run-validation.sh --quick    # 74/74
tools/dev/run-validation.sh            # 94/94

# Phase 6 — production zero-mutation
<authority digests re-taken and diffed against the pre-checkpoint capture>
stat -c '%U:%G %a' /var/lib/kyri/artifacts ; touch /var/lib/kyri/artifacts/.probe   # refused
find /var/lib/kyri/artifacts -type f -printf '%TY-%Tm-%Td %p\n'
```

## Appendix B — the transaction, stated once

```
install-generation-11.sh --install
        │
        ├── require_repository            branch, reviewed commit, ancestry, clean tree
        ├── require_source_digests        nine blobs == nine pinned digests, at 6016d4f
        ├── require_closed_closure        matrix == closure(inspection) − already-installed
        │                                   ← the gate with no Generation-10 analogue
        ├── require_gates_closed          G3 and G6.1B stay shut
        │
        ├── require_no_foreign_package_objects   nothing undeclared in tools/fabric
        ├── require_gen10_baseline        48 objects, both directions against G10 evidence
        ├── require_target_state          all nine pathnames genuinely free
        ├── require_no_transaction_residue
        ├── require_same_filesystem       every target stages beside itself
        │
        ├── PREPARE                       ── PREPARING: unwinds on any exit
        │     ├── mkdir tools/fabric      0755 root:root; provenance journalled
        │     ├── materialise all nine from the commit object
        │     ├── chmod 0444, chown root:root, verify digest and mode
        │     └── journal PREPARED        ── the staged set is now the transaction's
        │
        ├── verify_prepared_set           all nine verify BEFORE any publication
        │
        ├── COMMIT                        ── consumes prepared bytes only; no git
        │     └── for each of nine:  journal → rename(2) → fsync
        │                            → verify digest, mode, root:root
        │                            → journal progress
        │     └── journal COMMITTED       ── THE COMMIT POINT
        │
        └── after the commit point, bookkeeping only; no failure reverts:
              write_evidence              gen11 written, gen10 preserved
              cleanup_transaction_artifacts
              verify_installed_set        nine digests, nine modes, directory, count 57
              verify_excluded_absent      write path, operator input, Trust plane
              verify_unchanged_surface    all 48 Generation-10 objects exactly as accepted

Before COMMITTED  →  rollback REMOVES what landed, fenced by digest, and removes
                     the directory only if this transaction created it.
Unknown bytes     →  never removed. Never restored over. Operator disposition.
Nine CREATEs. No REPLACE. 48 → 57. Every partial state fails closed.
```
