# ENG-0006-H6 — Health Store and Sequence Allocation

**Date:** 2026-10-22
**Branch:** `arch/eng-0006-health-runtime`
**Base:** `ec8e066` (H6 readiness assessment), on published H5 `97feaa4`
**Components:** **B1** (Health store) and **B2** (sequence allocation and identifier widths)
**Status:** IMPLEMENTED LOCALLY — READY FOR REVIEW
**Not done:** no push, no merge, no tag, no deploy. **`/var/lib/kyri/health` was not created and does not exist.**

---

## 1. Task

Implement the append-only Health record store and its identifier allocation, as
ENG-0006-D components B1 (`:186-193`) and B2 (`:195-200`) specify, on the
declared `ImmutableStore` base, with fixture roots only.

The brief superseded the earlier instruction that excluded B2, so B1 and B2
were implemented together. That resolves **Q-H6-2** (the scope conflict raised
by the readiness assessment) by operator ruling, not by my own judgement.

---

## 2. What was built

`tools/health/store.py` (247 lines) — `HealthStore(ImmutableStore)`, plus
`HealthStoreError`, `RECORD_DIRS`, `ID_PREFIXES` and `ID_WIDTHS`.

The module adds **no write path**. `tools/common/immutable_store.py` already
owns write-once-via-`os.link`, flock'd monotonic allocation, and the absence of
any update or delete method; ENG-0006-D names it as the declared base precisely
so the Health plane does not grow a fourth copy of it. What H6 adds is the part
that is actually Health-specific:

| Addition | Why it is not inherited |
|---|---|
| six families derived from `records.KINDS` | so the store cannot name a family the record model does not define, and a seventh cannot appear in one place only |
| `write_record()` override | the base reads `record.id`; **a Health record has no `id`** |
| `validate()` override | the base reads `record.get("id")`; against this store it would report every correct record as broken |
| `path_for()` fullmatch | `match` on a `^...$` pattern admits a trailing newline — see §4 |
| root and directory vetting | symlinked roots, another plane's storage, and the production root are refused *before* anything is created |

**Resolved Q-H6-1 (undeclared directory names).** The names are derived as
`f"{kind}s"` from the record model's own `KINDS` rather than restated as a
literal table. No authority declares them, so deriving them means there is
nothing to drift: a name cannot disagree with the family it belongs to. The
suite pins the derivation (`directory == kind + "s"` per family) so a future
change is visible.

**Resolved Q-H6-3 (`validate()`'s undeclared Health contract).** Implemented as
the narrowest reading: per family, read the declared identity field, fullmatch
it against the family's committed pattern, require the filename to equal it,
and report `.tmp` residue, a non-mapping file, an unreadable file, a symlinked
record file and a symlinked record directory. It **repairs nothing** — asserted
by comparing the on-disk file list across a `validate()` call.

**Two deliberate non-decisions.** H6 does not interpret record *content* (that
is H2's referential integrity, not filesystem validation), and it does not
decide *when* a record should be written.

---

## 3. Two findings that change the readiness assessment

**Finding B1 — `write_record()` must be overridden, and the readiness
assessment missed it.** The assessment (`ec8e066`) flagged only the `validate()`
override. But the base is:

```python
def write_record(self, kind: str, record) -> Path:
    return self.write_atomic(self.path_for(kind, record.id), record.to_dict())
```

and `HealthRecord.__getattr__` raises for any field the family does not define:

```
record.id -> AttributeError: id
```

So **every** write through the inherited method would have failed, not just
validation. Measured, then confirmed as a caught mutation (§6). The readiness
assessment is incomplete on this point; this report is the correction.

A consequence worth recording: because the six identity field names are unique
per family, reading the declared identity field is *also* what refuses a record
handed to the wrong kind. No separate kind check was added — it would have been
a second mechanism for a property the first already has.

**Finding B2 — H1 accepts an identifier carrying a trailing newline.**
`records.py`'s `_identifier` uses `PATTERNS[family].match(value)`, and in Python
`$` also matches immediately before a trailing newline:

```
'CHENV-0001'       match=True   fullmatch=True
'CHENV-0001\n'     match=True   fullmatch=False
'CHENV-0001\nx'    match=False  fullmatch=False
'CHENV-0001 '      match=False  fullmatch=False
```

H1 therefore **accepts** `envelope_id='CHENV-0001\n'` and returns it verbatim.
`ImmutableStore.path_for` uses the same `pattern.match`, so such an identifier
would have produced a **filename containing a newline**.

This is the same defect class as the H1C decimal `^...$`-vs-`fullmatch` finding
already fixed in `_DECIMAL_TEXT`, surviving in the identifier path.

**I did not fix it in `records.py`.** Changing H1's accepted input set is a
record-model contract change, outside this increment, and the brief forbids
resolving unrelated questions. What H6 does instead is refuse to *build a name*
from it: `path_for` fullmatches, so the store refuses the identifier, and
`validate()` fullmatches, so a newline-bearing record already on disk is
reported rather than blessed. Both are pinned by tests, including a fixture
file whose name *and* identity field both carry the newline — the only case
that distinguishes `match` from `fullmatch` in validation, since under `match`
the pattern and the filename would agree and the file would pass as valid.

**Recorded as Q-H6-4 for the reviewer** (§9): H1 should probably fullmatch
identifiers, as it already fullmatches decimals. H6 does not depend on that
being done.

---

## 4. Path and root safety

| Refused | Mechanism |
|---|---|
| a root that is a **symlink** | checked on the given path **before** `resolve()`, because resolution is what destroys the evidence |
| a root at or inside `/var/lib/kyri/fabric` or `/var/lib/kyri/trust` | `is_relative_to` against declared constants, unconditionally |
| **provisioning** `/var/lib/kyri/health` | `is_relative_to`, but only when `initialize=True` |
| a symlinked record directory, or one that is not a directory | `_directory()` override, so it is re-checked on every path construction, not only at `__init__` |
| a symlinked record path | `path_for()` |
| an identifier that is not a fullmatch | `path_for()` |
| an unknown record kind | `path_for()`, `identifier_of()` |

**The production refusal is tied to provisioning, not to reading**, so a future
read-only adapter (H14) is not locked out of a store an operator has already
created. H6 creates nothing: `open_for_read` on an absent root is asserted to
leave the root absent while still reporting empty counts and no problems.

**Path containment is structural, not checked.** A fullmatched identifier is a
fixed prefix plus digits, which cannot express `/` or `..`, so no identifier
that passes can leave its directory. Eleven traversal and malformation
fixtures are asserted refused, and the directory asserted still empty
afterwards. A redundant containment check was deliberately not added; the
fullmatch is what makes it unnecessary, which is why the fullmatch is pinned.

---

## 5. Guard amendments — four, not the two that were anticipated

The brief anticipated two coordinated edits (permit the import; change the
policy pin). **Four guards actually refused the module**, all four measured
before any was touched:

```
FAIL: unapproved health implementation file(s): tools/health/store.py
FAIL: a health module imports a network, concurrency or storage module
FAIL: a health module leaves its package: tools/health/store.py:
      from ..common.immutable_store import ... (relative, resolves to tools.common)
FAIL: a health module names a store, an allocator or a production root
```

**(1) The cross-plane import — authorised as narrowly as the guard can express.**
`HEALTH_PERMITTED_PLANE_IMPORTS=("tools.common.immutable_store")`, **not**
`tools.common`. The guard matches on exact name or dotted prefix, so naming the
module admits the one module H6 needs while every other future member of
`tools.common` must come back for its own increment.

**(2) The policy pin, changed from emptiness to exact content.** H4B could
assert the set was empty. Now that one import is authorised, emptiness is no
longer the property to hold — and "non-empty" would be no property at all, since
it would accept `tools.trust`. The pin now spells out the expected contents
exactly, and five named planes (`tools.trust`, `tools.fabric`,
`tools.capability`, `tools.observation`, **and `tools.common` itself**) are
asserted *absent* from the permitted set.

**(3) NOT ANTICIPATED — a serialiser exception was also required.** `yaml` is
forbidden to every Health module by an existing import guard, and `validate()`
has to parse the records it reports on. I considered laundering the parse
through the base's `read_record()` to avoid the import; it still needs
`yaml.YAMLError` to report a corrupt file rather than raise, so that would have
been contortion for appearance. The exception is instead a **file/module pair**,
`tools/health/store.py:yaml`, pinned by exact content. Every other Health
module still imports no serialiser, and the store still imports no socket, no
subprocess and no concurrency facility — the forbidden list itself is unchanged.

**(4) NOT ANTICIPATED — an existing assertion directly contradicted H6.**

```bash
grep -rqE 'ImmutableStore|allocate_id|/var/lib/kyri' "${ROOT}/tools/health" --include='*.py'
# -> "no health module names a store, an allocator or a production root"
```

This was written when the plane had no store. **Deleting it would have
retired a real guard for the other six modules**, which must still not reach
storage. It was scoped rather than deleted, and then hardened twice, because
the first scoping was defeated by a mutation (§6):

- the exemption is an array pinned by exact content;
- **each pure module is additionally checked by name** — a scan with an
  exemption list can be widened, an enumeration cannot be without deleting a
  line that says which module stopped being checked;
- and the store is separately asserted to contain no provisioning verb beside a
  production path.

**One consequence to flag:** the permitted-import set is **per package, not per
module**. Authorising `tools.common.immutable_store` authorises it for every
Health module, so the AST guard alone would no longer stop an *evaluator* from
importing `ImmutableStore`. The per-module enumeration in (4) is what closes
that, and it is proven to fire even when the generic scan is bypassed (§6).

**Also amended, as consequences rather than authorisations:**

- the closed module allowlist in all four suites gained `tools/health/store.py`
  as its **seventh** entry;
- the fixture intruder battery lost `store.py` (now approved) and gained eight
  store-shaped intruders — `store`, `stores.py`, `store_v2.py`, `store.pyc`,
  `xstore.py`, `store_adapter.py`, `store_collector.py`, `record_store.py` —
  so the battery still proves a store-*shaped* name is refused;
- the compliant fixture tree now also copies `store.py`;
- `test-health-conditions.sh` asserted `not hasattr(PKG, "store")`. The package
  now has a `store` **submodule**, which is not the condition evaluator
  acquiring the ability to store anything. The prohibition was **sharpened, not
  relaxed**: the evaluator and the record model are asserted to expose no
  `store` and no `HealthStore` at all, and the package is asserted to expose no
  `store` **callable** and only a module under that name;
- `test-docs-static.sh` rule 4 (every store-building suite must root its stores
  in a temporary directory) now lists `test-health-store`;
- `PRODUCTION_ROOT` and the two foreign-plane constants carry the repository's
  existing `# prod-path-reference` marker, which is the established convention
  for a line that legitimately names a production path.

### 5.1 The package docstring, and a disclosed H5 omission

`tools/health/__init__.py`'s docstring asserted "**nothing is stored** … and
nothing is imported from any other plane". H6 makes both clauses false, so the
paragraph was corrected and a `store` bullet added.

**Disclosure:** that same paragraph was *already* wrong before H6. It said "No
hysteresis is decided" and its header read "ENG-0006-H1 through H4" — both
left stale by H5, which added `hysteresis.py` without updating this file. I
corrected those too rather than edit around a sentence I knew to be false
while rewriting it. The H5 report did not record this omission; this paragraph
is the correction. No other pre-existing content was touched.

**The guard then caught my own prose.** The reworded docstring named
`ImmutableStore`, and the per-module enumeration of §5(4) immediately failed
`tools/health/__init__.py` on **two** assertions. The scan is lexical, so prose
about storage trips it exactly as code would. I **reworded the docstring rather
than widen the exemption** — the guard loses nothing, and the cost is one
sentence that says "the platform's shared write-once storage base" instead of
naming the class. This is recorded because it is the kind of friction a future
increment will meet, and the resolution should be the same one.

---

## 6. Mutation testing

**28 behaviour-changing mutations, applied one at a time and reverted before
the next. All 28 are caught** — after three survivors on the first pass were
closed. First pass: 23 of 26 caught. Second pass after the fixes: 25 of 25
caught (one of the original 26 had been rewritten by a fix, so its anchor no
longer existed and it was replaced by a sharper mutation of the new code).
Three further guard mutations were then run separately, all caught.

**Caught, on `tools/health/store.py`:** `fullmatch`→`match` in `path_for`;
removing the root symlink check; moving that check *after* `resolve()`;
removing the foreign-plane refusal; removing the production-root refusal;
narrowing it to exact equality so a path *inside* the production root passes;
removing `_directory` vetting; `_vetted_directory` ignoring symlinks;
`write_record` falling back to the base `record.id`; `identifier_of` letting
`AttributeError` escape; `validate` reading `id`; `validate` matching instead
of fullmatching; `validate` no longer reporting the symlinked directory, a
symlinked record file, or `.tmp` residue; `validate` raising on a corrupt file
instead of reporting it; dropping O_EXCL; widening the envelope to six digits;
dropping a family from the layout; dropping the sequence directory; removing
the record-path symlink check.

**Caught, on the amended guards:** widening the permitted import to
`tools.common`; permitting a second plane alongside it; moving the serialiser
exception to `records.py`; widening the storage-name exemption array to an
evaluator; adding an eighth entry to the module allowlist; planting
`from ..common.immutable_store import ImmutableStore` into `conditions.py`
(**two** assertions fire — the scan and the enumeration); and that same plant
*with the scan additionally given an inline bypass for `conditions.py`*, where
the enumeration still fires alone. The mutated guard was confirmed to still
parse before that result was accepted — an earlier attempt produced a
nonzero exit from a bash syntax error of my own, which is not evidence of
anything and is not counted here.

**The three first-pass survivors. All three were real test gaps.**

1. **Removing the record-path symlink check.** A write through a planted
   symlink is refused *by the shared write path anyway* — `os.link` fails on an
   existing name — so my assertion proved the base, not the store's own check.
   What the check uniquely prevents is **reading**: without it, a record read
   through a planted symlink would return content from outside the store and
   report it as stored. Closed with four assertions: reading is refused,
   resolving the path is refused, `validate()` never echoes the symlink
   target's contents, and allocation refuses rather than skipping the name.
2. **`validate` matching instead of fullmatching.** Every fixture I had was
   reported either way — under `match` the trailing newline passes the pattern
   but then `path.stem != identifier` fires. The only distinguishing case is a
   file whose **name and identity field both** carry the newline, which Linux
   permits; under `match` the pattern and the filename agree and the file is
   blessed as valid. Closed with exactly that fixture.
3. **Widening the storage-name scan's exemption to an evaluator.** Nothing
   pinned the exemption — the same defect class H4B fixed with a policy pin.
   Closed by pinning the exemption array *and* enumerating the pure modules by
   name.

**Two mutations that are correctly no-ops, and are not counted above.**
Deleting a module from the enumeration, or adding an inline bypass clause to
the scan, changes no behaviour on its own: there is nothing planted for the
weakened check to miss, so no assertion can fail. Their meaningful form — weaken
the guard **and** plant the violation — is in the caught list. No guard can
catch an arbitrary edit to its own enforcement code; what H4B's standard asks
for does hold, because no forbidden identifier or exemption can be changed in a
single constant that both the enforcement and the pin read.

**One honest limit on the production-root result.** Both production-root
mutations were caught, but on this host the *first* observable error was
`PermissionError` rather than the store's refusal, because `/var/lib/kyri` is
`0711 root:root`. The suite demands a store error specifically, so the mutation
is caught for the right reason — but on a host where that path were writable,
removing the refusal would create the production root. What the test pins is
the behavioural refusal, not the filesystem's permissions.

## 7. Tests executed

| Suite | Result |
|---|---|
| `tests/test-health-store.sh` (**new**, 191 assertions) | **PASS** |
| `tests/test-capability-health.sh` (553) | **PASS** |
| `tests/test-health-records.sh` (694) | **PASS** |
| `tests/test-health-conditions.sh` (297) | **PASS** |
| `tests/test-health-freshness.sh` (217) | **PASS** |
| `tests/test-health-hysteresis.sh` (206) | **PASS** |
| `tests/test-health-binding.sh` (87) | **PASS** |
| `tests/test-capability-health-agreement.sh` (88) | **PASS** |
| `tests/test-capability-fabric.sh` | **PASS** |
| `tests/test-static.sh` | **PASS** |
| `tests/test-docs-static.sh` | **PASS** |

**RED before GREEN.** At the pre-implementation tree the new suite ran
**9 PASS / 1 FAIL**, failing at `ImportError: cannot import name 'store' from
'tools.health'` — the nine passing assertions are the schema oracle, which
reads the committed schemas and must hold with or without the module. The four
guards were then measured refusing `store.py` (§5) before any guard was edited.

`bash -n` and `shellcheck` are clean on all six touched suites.

**Full validator:** see §8.

---

## 8. Validation baseline

| | executed | passing | failing |
|---|---|---|---|
| baseline before H6 | 158 | 130 | 28 |
| after H6 | **159** | **131** | **28** |

One more suite executed and one more passing: the new `test-health-store.sh`.
The failing set is **identical, compared name by name** — nothing newly
failing, nothing newly passing:

```
newly failing:      (none)
no longer failing:  (none)
identical membership: YES
```

**A false result I had to discard first.** The initial comparison reported all
28 as both "newly failing" and "no longer failing", with
`identical membership: NO`. That was an artefact of my own tooling: the
recorded baseline file stores suite names *with* the `.sh` suffix and the new
run recorded them *without*, so `comm` matched nothing. The sets were in fact
identical. The measurement above is the re-run with the names normalised. The
counts (159/131/28) were never affected.

A second measurement was also discarded: the first full run was started before
the `__init__.py` docstring correction of §5.1 landed, so it measured a tree
that no longer existed. It was abandoned and re-run from the final tree rather
than reported with a caveat.

The 28 pre-existing failures are the known generation-installer and
helper-ceremony validation debt, dominated by suites that hard-code
`REPOSITORY="/opt/schott-platform"`. They are unrelated to H6 and were failing
before it. **The suite as a whole is not GREEN and is not described as GREEN.**

`tools/dev/run-validation.sh` gained one step (`run "Health store"`) with
`TOTAL_STEPS` 148→149 (quick) and 173→174 (full). The step sits outside every
`if (( QUICK == 0 ))` block — the last such block closes at `:340` and the step
is at `:1114` — so it runs in both modes and both totals rise by exactly one.
The script self-checks that the declared total equals the number of steps that
actually ran, so a miscount fails the validator rather than passing quietly. `.github/workflows/ci.yml`
gained the matching job step.

---

## 9. Questions for the reviewer

**Q-H6-4 — should H1 fullmatch identifiers?** `records.py:_identifier` uses
`match` on `^...$` patterns and therefore accepts a trailing newline (§3). H6
refuses to build a filename from such an identifier, so nothing in the store is
at risk, but H1 still *accepts* the record. The decimal path was already fixed
this way in H1C. This is a record-model contract change and I did not make it.

**Q-H6-5 — the permitted-import set is per package, not per module.** Does the
reviewer want the AST guard taught to express *module*-scoped permissions
(`tools/health/store.py` may import `tools.common.immutable_store`; no other
Health module may), rather than relying on the per-module enumeration added in
§5(4)? That is a guard change, not an H6 requirement, which is why it is a
question and not a commit.

**Q-H6-6 — is `HealthStoreError = StoreError` the intended surface?** The store
re-exports the shared exception rather than subclassing it, so a caller has one
type to catch rather than two that mean the same thing. A subclass would let
callers distinguish Health failures, at the cost of the base's own refusals not
being Health errors. I chose the single type; it is reversible.

---

## 10. Known risks

- **The store is unexercised by any producer.** Nothing writes Health records
  yet. B1/B2 are proven by this suite, not by use.
- **Concurrency is proven in-process.** 80 identifiers across 4 threads are
  asserted unique and unbroken. The lock is `flock`, so it is cross-process by
  construction, but no cross-process test was written.
- **`validate()` grows with the store.** It is O(files) and reads every record.
  Fine at fixture scale; unmeasured at production scale.
- **The newline hole remains open at the H1 layer** (Q-H6-4).
- **Permissions are best effort.** The base swallows `chmod` failures by
  design, so 0700/0600 is asserted on this filesystem, not guaranteed on all.
- **`counts()` is not routed through the directory vetting.** It is inherited
  unchanged and globs `self.root / directory` directly, so a symlinked record
  directory would be *counted* rather than refused — `path_for`,
  `read_record`, `list_records` and `write_record` all refuse it, and
  `validate()` reports it. I left `counts()` alone rather than add a fifth
  override for a number; a reviewer who wants the refusal uniform across every
  read should say so.
- **The newline fixture tracks Q-H6-4.** The suite accepts either H1 behaviour
  (accepting the identifier, or refusing it once Q-H6-4 is fixed) and asserts
  only that it never becomes a filename, so fixing H1 will not break this
  suite.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H6 — implement components B1 (Health store) and B2 (sequence
allocation and identifier widths) on the declared `ImmutableStore` base, with
fixture roots only.

**Files Changed:**
- `tools/health/store.py` — **new**, 247 lines. `HealthStore`, `HealthStoreError`,
  `RECORD_DIRS`, `ID_PREFIXES`, `ID_WIDTHS`, `PRODUCTION_ROOT`,
  `FOREIGN_PLANE_ROOTS`.
- `tools/health/__init__.py` — re-export `HealthStore`, `HealthStoreError`
  (`__all__` 22 → 24 names); docstring corrected (§5.1), including two
  statements left stale by H5.
- `tests/test-health-store.sh` — **new**, 191 assertions. Fixture roots under a
  `tempfile.mkdtemp` tree, removed by an `atexit` hook as well as by the
  asserted explicit removal, so an **aborted** run leaves nothing behind —
  twelve stray roots from the mutation runs are what prompted that.
- `tests/test-capability-health.sh` — the four guard amendments of §5.
- `tests/test-health-conditions.sh` — `store` prohibition sharpened.
- `tests/test-capability-fabric.sh`, `tests/test-static.sh`,
  `tests/test-docs-static.sh` — seventh allowlist entry; plus rule 4
  registration in `test-docs-static.sh`.
- `tools/dev/run-validation.sh` — one step; `TOTAL_STEPS` 148→149, 173→174.
- `.github/workflows/ci.yml` — one job step.
- `docs/development/reports/eng-0006/2026-10-22-eng-0006-h6-health-store.md` — this report.

**Tests Executed:** the eleven suites in §7, all passing; the new suite proven
RED (9 PASS / 1 FAIL) before implementation; 28 behaviour-changing mutations,
all caught (§6); the full validator, in §8.

**Commands Run:** `bash tests/test-*.sh` (individually and across all suites);
`bash -n` and `shellcheck` on all six touched suites; `python3 -c "import ast;
ast.parse(...)"`; the mutation harness; `git status`, `git log`.
No `git push`, `merge`, `rebase`, `tag`, or deploy. No write to
`/var/lib/kyri`, Fabric or Trust storage. No production service, credential or
permission touched.

**Known Risks:** §10.

**Architecture Decisions:**
1. Directory names **derived** from `records.KINDS`, not restated (Q-H6-1).
2. `validate()` implemented to the narrowest defensible Health contract (Q-H6-3).
3. `write_record()` overridden — the readiness assessment had missed this.
4. `path_for()` and `validate()` **fullmatch**; the newline defect is contained
   at the store boundary and **left unfixed at the H1 layer** (Q-H6-4).
5. The production-root refusal is scoped to **provisioning**, not reading.
6. The cross-plane authorisation is `tools.common.immutable_store`, not
   `tools.common`; a **second** exception (`yaml`, store-only) was also
   required and is pinned as a file/module pair.
7. The contradicting storage-name guard was **scoped and hardened**, not
   deleted, and backed by a per-module enumeration.
8. `HealthStoreError = StoreError` rather than a subclass (Q-H6-6).
9. No separate record/kind check: the per-family identity field already is one.
10. The package docstring was reworded to satisfy the lexical storage-name
    guard, rather than the guard's exemption being widened to cover prose.

**Questions for Reviewer:** Q-H6-4 (should H1 fullmatch identifiers), Q-H6-5
(module-scoped import permissions), Q-H6-6 (error-type surface) — §9.
