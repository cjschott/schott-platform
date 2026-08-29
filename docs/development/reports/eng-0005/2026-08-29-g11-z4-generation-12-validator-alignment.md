# ENG-0005 G11-Z4 — Post-Generation-12 validator baseline and invocation-contract alignment

**Date:** 2026-08-29
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `b6accf11142e6b284fa7b3d5f2ad8f12de579fe0`
**Implementation commit:** `a2e4bee10a5e050975f1a4fb6e6ceb5f44c6eb85`
**Predecessor:** G11-Z3 (`b6accf1`), G11-Z2 report `fc4e6d2`

Three suites encoded a Generation-11 live host and went red the moment
Generation 12 was installed. They are corrected to assert the accepted
Generation-12 runtime and the current G11-X/G11-Y invocation contract. Quick and
full validation are green. Nothing in production was written.

---

## 1. Starting authority — and one correction to the brief

The brief names "the final pushed G11-Z3 report commit" as the starting HEAD.
**No such commit exists.** G11-Z3 stopped for the operator's read-only
`--verify-installed` before writing its report, exactly as its own Phase 8
required, so its last commit is the implementation `b6accf1`. That is the
authority this checkpoint started from.

Two G11-Z3 items therefore remain open and are carried forward unchanged:

- the live `sudo bash provisioning/execution/install-generation-12.sh --verify-installed`
  proving the corrected Generation-12 banner on the real host;
- the G11-Z3 report, which that output gates.

Neither blocks this checkpoint: G11-Z3's correction is committed, pushed and
proved by fixture, and this checkpoint touches only test expectations.

| Check | Observed |
| --- | --- |
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `b6accf11142e6b284fa7b3d5f2ad8f12de579fe0` |
| `origin/…` | identical to HEAD |
| Working tree | clean |
| Installed `.py` objects | 70 |
| Aggregate runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| `tools/trust/` | exactly the 10 declared read-path modules |
| `/etc/sudoers.d/` | `README` only |
| Privileged helpers | unchanged |
| Fabric / Trust / Evidence+Artifacts | `bcb2559b…` / `cffd362c…` / `1f58bad3…` |
| Root Authority | `/var/lib/kyri` `drwx--x--x root:root`, not a separate mount |

## 2. Independent RED reproduction

Each suite run on its own before any edit.

| Suite | Exit | Failures | Class |
| --- | --- | --- | --- |
| `test-capability-execution-generation12-packaging.sh` | 1 | 8 | A — live-runtime generation baseline mismatch |
| `test-capability-execution-generation11-installer.sh` | 1 | 1 | B — installed closure expectation mismatch |
| `test-fabric-runtime-install-closure.sh` | 1 | dies before its verdict | C — invocation API/authority contract mismatch |

Quick validation stopped at **step 14**, `FAILED: Generation-12 packaging`.

No unrelated failure appeared. G11-Z3 had already proved these three fail
identically at the pre-Z3 HEAD, so the reporting correction is not the cause;
the installation is.

The third suite is the interesting one. It did not report a failed assertion —
it printed every assertion as PASS and then exited 1 without a verdict, because
`set -Eeuo pipefail` killed it mid-file. The real error only appears on stderr:

```
TypeError: verify_selected_evidence() missing 2 required keyword-only arguments: 'operation' and 'trust_root'
```

**That suite fails because G11-X works.** The installed runtime refuses a caller
that omits the explicit operation, which is precisely the authority G11-X
introduced. The test predates it.

## 3. Stale assumption per suite, and the correction

### 3.1 Generation-12 packaging — the live host is not the baseline

PART 1 exists to prove the Generation-11 surface no longer closes the import
graph, which is *why* Generation 12 exists. It computed that surface as
`installed`, read from `/usr/lib/kyri/python`. That was a true shorthand only
while the live host was Generation 11.

The subject is the predecessor surface, so it is now derived rather than
observed:

```python
created_here = {row[0] for row in MATRIX if row[3] == "CREATE"}
gen11_surface = sorted(set(installed) - created_here)
```

What is installed now, less the pathnames this generation creates, is exactly
what the predecessor held — 70 − 13 = 57.

That derivation is sound only while the live host is the generation this suite
pins, so that is asserted first, by digest and not by count:

```
PASS: the live host is the Generation 12 this suite pins (19/19 declared rows at their target digests)
```

This is the Part F requirement met concretely: on Generation 13 the suite fails
naming the generation, instead of reporting "expected 57, got 70".

| Assertion | Subject before | Subject after |
| --- | --- | --- |
| missing reachable modules | live tree (wrongly) | derived Generation-11 surface |
| the six named stale families | live tree | derived Generation-11 surface |
| object count 57 | live tree | derived Generation-11 surface |
| object count 70 | — | live tree (**added**) |
| 19 rows at target digests | — | live tree (**added**) |

PART 2 onward was already correct: `packaged = installed ∪ declared` is 70 on a
Generation-12 host and needed no change. Source-package and isolated-fixture
assertions were not touched.

**53 PASS / 0 FAIL.**

### 3.2 Generation-11 installer — the exclusion list went stale twice

The live-host block already carried a comment recording that asserting
"Generation 11 is not installed" had bound the suite to the day it was written.
That correction was made when Generation 11 went in, and it did not go far
enough: it still enumerated the modules that may never appear, and Generation 12
legitimately installs three of them — `eligibility.py`, `trust_adapter.py`,
`resources.py`. The same class of mistake, one generation later.

The durable invariant is not "the package holds exactly nine objects". It is
**the write and decision plane is never installed**. Read-path additions are now
read from the later generation that declares them:

```bash
mapfile -t later_fabric < <(
  sed -n 's/^"\(tools\/fabric\/[a-z_]*\.py\)|.*|CREATE|.*$/\1/p' \
    "${REPOSITORY}/provisioning/execution/install-generation-12.sh" | sed 's#^tools/fabric/##')
expected_fabric=$(( ${#ROWS[@]} + ${#later_fabric[@]} ))
```

`admission.py`, `cli.py` and `selection.py` remain unconditionally refused, and a
new check refuses any Fabric module that *neither* Generation 11 *nor* a later
generation declared — strictly stronger than the fixed list it replaces.

```
PASS: production carries the reviewed Fabric closure: 9 Generation-11 objects plus 3 later-generation read-path modules, no write-plane module
```

**Historical coverage preserved.** The Generation-11 fixture assertions are
untouched, including `the installed Fabric package is exactly the nine-file
closure`, which runs against the controlled G11 fixture and still proves the
historical installer's semantics. Nothing was moved or deleted to make the live
host pass.

**122 PASS / 0 FAIL.**

### 3.3 Fabric runtime install closure — the invocation contract moved

The suite called the pre-G11-X signature. The correction supplies the authority a
real invocation supplies, rather than relaxing the call:

- **explicit operation** — `operation='execute'`;
- **Trust reader authority** — a real `TrustStore` root, constructed the same way
  the existing `FabricStore` fixture is;
- selection, instance, package and the timezone-aware evaluation instant, all
  already present.

No dummy default was introduced. The empty-store refusal is retained as the
closure proof — reaching a refusal means every transitive import resolved — and
three assertions were added so the runtime's authority is pinned here rather
than merely accommodated:

```
PASS: the Capability to Fabric path executes from the installed surface alone
PASS: the installed boundary requires an explicit operation, with no default
PASS: an operation naming nothing is refused rather than inferred
PASS: the Trust reader the invocation boundary now depends on resolves from the installed surface
```

The negative assertions are deliberately the two cheapest ones — omission raises
`TypeError`, and a whitespace operation refuses with `operation-not-supplied`.
The full four-dimensional scope and eligibility matrices are not duplicated here;
they belong to the dedicated G11-X and G11-Y suites, which both remain green.

Supplying `trust_root` widened what this suite proves: the Trust reader is now
part of the dependency graph the Capability boundary closes over, so
`tools.trust` must resolve from the installed surface too — asserted explicitly.

**17 PASS / 0 FAIL.**

## 4. Installed-runtime import proof

The closure suite runs every check through `isolated()`, which unsets
`PYTHONPATH`, runs `python3 -E` from `/`, and rewrites `sys.path` to the
disposable root plus system paths with every `schott-platform` and `/opt` entry
removed. The disposable root is built from `/usr/lib/kyri/python`. Two standing
assertions make that meaningful and both pass:

```
PASS: no tools module resolved from outside the disposable root      (STRAYS [])
PASS: the repository is not on the isolated interpreter's path       (REPO_ON_PATH False)
  LOADED 36
```

So an incomplete installed closure cannot be masked by repository source. The
negative control — removing `tools/fabric/models.py` — still fails naming exactly
that module.

## 5. Focused regression

| Suite | Exit | PASS | FAIL |
| --- | --- | --- | --- |
| Generation-11 installer | 0 | 122 | 0 |
| Generation-12 packaging | 0 | 53 | 0 |
| Generation-12 installer | 0 | 77 | 0 |
| Fabric runtime install closure | 0 | 17 | 0 |
| G11-X operation authority | 0 | 55 | 0 |
| G11-Y current eligibility | 0 | 49 | 0 |
| Capability runtime | 0 | 1077 | 0 |
| Fabric runtime | 0 | 8336 | 0 |
| Trust runtime | 0 | 518 | 0 |
| Fabric G11 integrity | 0 | 91 | 0 |

`pre-commit` on the three changed files: all five hooks pass, including
ShellCheck at the pinned 0.9.0.

## 6. Validation

Both run with a captured PID and judged by the validator's own exit status and
final line. No `pgrep`.

| Mode | Steps | Exit | Result |
| --- | --- | --- | --- |
| Quick | 78/78 | 0 | `Validation passed (quick mode), started 2026-08-29T16:16:24-05:00, 78/78 steps.` |
| Full | 101/101 | 0 | `Validation passed (full mode), started 2026-08-29T16:22:40-05:00, 101/101 steps.` |

Totals are read from the runs, not assumed. They match the G11-Z1 totals, which
is expected: this checkpoint corrected assertions inside existing suites and
registered no new suite.

## 7. Production no-mutation proof

Taken after every suite and both validators had run.

| Surface | Before | After |
| --- | --- | --- |
| Installed `.py` objects | 70 | 70 |
| Aggregate digest | `9cbfd043…33830` | `9cbfd043…33830` |
| Per-file runtime manifest | — | byte-identical (`diff` clean) |
| Fabric store | `bcb2559b…f15e` | unchanged |
| Trust store | `cffd362c…bc39` | unchanged |
| Evidence + Artifacts | `1f58bad3…4f9c07` | unchanged |
| Privileged helpers | `a327a5fb…` (digest set) | unchanged |
| `/etc/sudoers.d/` | `README` only | unchanged |

Chain records byte-identical: CADV-000003 `f2b48c2e…`, CINST-000002 `5cfcf01e…`,
CROUTE-0002 `1a7ed018…`, CSEL-000001 `e08a4df4…`. The governed chain
CADV-000003 → CINST-000002 → CROUTE-0002 → CSEL-000001 is intact and untouched.

`/var/lib/kyri` is `drwx--x--x root:root` and not a separate mount. No privileged
command was run in this checkpoint; no `/root` path was read or written.

## 8. Actions not performed

No install, reinstall or recover. No stage, no invoke, no CINV, no adapter, no
execve. No sudoers installed. No journal or evidence file read, written or
modified. No Fabric, Trust, Artifact or Platform Evidence mutation. No Generation-12
runtime behaviour weakened to accommodate a test. No historical Generation-11
coverage deleted. No failing assertion removed rather than corrected. None of the
three carried-forward hardening items addressed.

## 9. Readiness for the stage/invoke preflight

The validators are green against the runtime that is actually installed, which is
what they were not before. The three corrected suites now assert Generation 12
and the current invocation contract rather than bypassing either, and two of them
prove strictly more than they did: the packaging suite pins the live generation
by digest, and the closure suite pins the explicit-operation requirement and the
Trust reader's resolution.

`PRODUCTION_INVOKE_AUTHORISED = NO`.

Outstanding before or alongside the next checkpoint:

1. **G11-Z3's live `--verify-installed`** and its report (§1). Read-only,
   operator-gated, tree is clean so the ceremony will accept it.
2. The **first stage/invoke preflight audit**, which must derive the exact invoke
   CLI and body, the required operation, current selected evidence, the adapter
   situation, stage artefacts, CINV identity, sudoers and helper authority, what
   executable actually runs, and rollback and containment — before anything is
   staged.

Carried forward unchanged:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`
- Privileged-helper drift remains separately governed and excluded.
