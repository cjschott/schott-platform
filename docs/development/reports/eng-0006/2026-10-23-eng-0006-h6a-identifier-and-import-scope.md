# ENG-0006-H6A — Identifier Full-Match and Module-Scoped Import Boundary

**Date:** 2026-10-23
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `87cc597aa17d8db0a677dabca49d53ffe61ee88f` (H6)
**Remote baseline:** `97feaa409b4a745d91c904f342517bef6d71102a` (published H5)
**Scope:** corrective only — resolves **Q-H6-4** and **Q-H6-5**
**Q-H6-6:** resolved by operator ruling — the `HealthStoreError = StoreError` alias is **retained unchanged**
**Status:** IMPLEMENTED LOCALLY — READY FOR REVIEW
**Not done:** no push, merge, rebase, tag, deploy, or production provisioning. **`/var/lib/kyri/health` remains absent.**

---

## 1. Preflight

| Check | Result |
|---|---|
| local HEAD | `87cc597aa17d8db0a677dabca49d53ffe61ee88f` — matches the expected H6 commit |
| ancestry | `87cc597` → `ec8e066` → `900dcea` → `97feaa4` → `8447e8c` → `2e2e2a3` |
| worktree | clean (`git status --porcelain` empty) |
| remote HEAD | `97feaa409b4a745d91c904f342517bef6d71102a`, exactly the expected published H5 |
| unpublished | three commits: `900dcea`, `ec8e066`, `87cc597` |
| production root | `/var/lib/kyri/health` — `No such file or directory` |

Inspected before any edit: `tools/health/records.py`, `tools/health/store.py`,
`tools/common/immutable_store.py`, `tests/test-capability-health.sh`, the H6
implementation report, and the six committed Health identifier schemas.

---

## 2. Correction 1 — Q-H6-4, identifiers are matched in full

### The single common path

Every Health identifier passes through exactly one function. `_identifier`
(`records.py:168`) is called 13 times — once per identity field per family,
plus the reference fields and the `_id_sequence` helper — and all six families
route through `PATTERNS[family]`. That was the whole of the change:

```python
-    if not isinstance(value, str) or not PATTERNS[family].match(value):
+    if not isinstance(value, str) or not PATTERNS[family].fullmatch(value):
```

The declared formats, widths, prefixes and error codes are **unchanged**. The
compiled patterns keep their `^...$` anchors: under `fullmatch` they are
redundant, but they are what the committed schema declares and `store.py`
shares the same constants, so removing them would have been a gratuitous edit.
§2.3 is what now stops them drifting.

**Scope boundary, stated deliberately.** `subject_id`, `collector_id` and
`source_fingerprint` are validated by `_text`, not by a pattern. That is H2's
committed contract — the subject-binding layer asserts nothing about the
existence, authenticity or format of a subject — so they are **not** touched
here. Q-H6-4 is about the six CH families, which is what "every Health
identifier family" names.

### 2.1 RED before GREEN, and what the RED actually proved

Negative fixtures were added first, for all six families plus the reference
fields, over sixteen extraneous-character shapes: `\n`, `\r\n`, `\r`, `\t`,
trailing space, leading space, leading newline, `\n` plus space, `\n` plus a
character, a doubled identifier separated by `\n`, a trailing character, a
trailing hyphen, a trailing digit, a `.yaml` suffix, `/..`, and `\x00`.

**RED: exactly 8 failures of 802 assertions.** Every one of them the trailing
newline:

```
FAIL: capability-health-envelope refuses 'CHENV-0001\n' as envelope_id: accepted
FAIL: capability-health-observation refuses 'CHOBS-000001\n' as observation_id: accepted
FAIL: capability-health-state refuses 'CHSTATE-000001\n' as state_id: accepted
FAIL: capability-degradation-event refuses 'CHDEG-000001\n' as event_id: accepted
FAIL: capability-health-recommendation refuses 'CHREC-000001\n' as recommendation_id: accepted
FAIL: capability-heartbeat refuses 'CHBEAT-000001\n' as heartbeat_id: accepted
FAIL: capability-health-state refuses 'CHENV-0001\n' as envelope_id: accepted
FAIL: capability-health-recommendation refuses 'CHSTATE-000001\n' as derived_from_state_id: accepted
```

**This is a sharper result than H6 reported, and it is worth stating plainly:**
*every other* extraneous shape was already refused. The defect was precisely
the trailing newline and nothing else — `$` matching before a final `\n` — not
general laxity in identifier validation. H6's report described the hole
correctly but did not establish how narrow it was.

One of the three reference-field cases did not fire: the degradation event's
`derived_from_state_id` is absent from that family's valid fixture, so the
loop skipped it. Two reference fields were exercised, not three.

**GREEN after the one-line change:** 802 → 809 assertions passing, zero
failures, and every Health suite still green (§5).

**A path the first fixture set missed.** `_id_sequence` validates each member
of `derived_from_observation_ids` through the same `_identifier`, and the
original fixtures only covered scalar fields. Thirteen sequence assertions were
added afterwards — a newline-bearing member alone, beside a valid member, and
in first position, plus a trailing space and a `.yaml` suffix — bringing the
suite to **819**. They are load-bearing: reverting to `match` now fails **14**
assertions, six of them in the sequence path. The 8-failure RED above is the
honest measurement of the fixture set *as first written*; 14 is the measurement
of the complete set.

### 2.2 The parser and the store now agree, asserted directly

Q-H6-4 was fundamentally a *disagreement*: the parser accepted an identifier
the store had to refuse, so the store carried a second barrier against its own
record model. Agreement is now asserted over one shared candidate set of
nineteen strings, rather than inferred from the two layers having similar code:
for each candidate, `records.parse()` accepting and `HealthStore.path_for()`
accepting must be the same answer, and exactly one candidate is valid.

**Both barriers are retained.** The store still fullmatches independently. It
is the layer that turns an identifier into a filename, so it must not depend on
the parser having been correct.

An H6 fixture that was written to tolerate *either* H1 behaviour correctly
detected the fix — `test-health-store.sh` went 191 → 190 assertions as its
tolerant branch switched — and has now been replaced by a direct assertion that
the record layer refuses to build such a record at all.

### 2.3 A gap found by mutation: nothing pinned the patterns to the schema

Dropping the `^...$` anchors from a compiled pattern **survived** the first
mutation pass. Under `fullmatch` the anchors are redundant, so removing them
changes no behaviour — but nothing compared the module's compiled patterns to
the committed schema's `id_pattern` at all. The suite used the schema pattern
as its *oracle* while the module's own copy went unchecked, so the two could
drift in any direction.

Closed by pinning each family's `H.PATTERNS[family].pattern` to
`SCHEMA[family]["id_pattern"]` byte for byte, plus an assertion that the module
compiles patterns for exactly the six families.
`tests/test-fabric-evidence-authority.sh:404` pins the Fabric's identifier the
same way; this is that existing precedent applied to Health.

---

## 3. Correction 2 — Q-H6-5, the permission is bound to one module

### The defect

H6 authorised `tools.common.immutable_store` for the **package**. The AST guard
read the permitted set as bare module names and applied it to every file, so
any Health module could have imported `ImmutableStore` and passed. The
authorisation was wider than its justification. H6 flagged this itself and
relied on the per-module storage-name enumeration to cover it; H6A fixes the
guard instead.

### The design — and why no redesign was needed

The guard already expressed a module-scoped rule: H6's serialiser exception is
the pair `tools/health/store.py:yaml`. The plane-import set now takes the same
shape:

```bash
HEALTH_PERMITTED_PLANE_IMPORTS=("tools/health/store.py:tools.common.immutable_store")
```

and the AST scan resolves permissions per file:

```python
def permits(relative_path, imported):
    """Whether THIS file is permitted THIS import, by exact name or dotted prefix."""
    return any(scope == relative_path
               and (imported == module or imported.startswith(module + "."))
               for scope, module in permitted_pairs)
```

Both cross-package dependencies are now expressed the same way and both are
scoped to `tools/health/store.py` alone. **No policy redesign was required, so
there is nothing to report as blocked.**

**Fail-closed by construction.** An entry with no `:` contributes no pair and
therefore permits *nothing*. A reviewer can verify this behaviourally: §4 shows
that widening the entry back to a bare `tools.common.immutable_store` causes
the store's **own** legitimate import to be refused, rather than quietly
re-enabling a package-wide permission.

### Four independent pins

1. **Content** — the set must equal `tools/health/store.py:tools.common.immutable_store` exactly.
2. **Shape** — every entry must match `tools/health/*.py:*.*`, so a bare module name is refused outright rather than relying on it being silently inert.
3. **Module half** — `tools.trust`, `tools.fabric`, `tools.capability`, `tools.observation`, `tools.common` and `tools` are each asserted absent from the *module* halves. Comparing module halves rather than whole entries is what stops `…:tools.common.immutable_store` being mistaken for a permission on `tools.common` by substring.
4. **File half** — only `tools/health/store.py` may appear on the left of any pair.

### The demonstration the brief asked for

Asserting that the compliant tree passes proves nothing about *scope* — it
would pass under a package-wide permission too. So both scans were made
root-parameterised (`health_ast_scan`, `health_host_import_scan`) and are
pointed at a fixture copy of the approved modules, which the suite may edit.
**91 new assertions**, all passing:

| Battery | Cases |
|---|---|
| the fixture copy of the approved tree scans clean | 1 |
| the fixture's store module really carries **both** authorised imports | 1 |
| 7 spellings of the approved store import × 6 other modules, each refused | 42 |
| 3 spellings of `import yaml` × 6 other modules, each refused | 18 |
| a **new** module named `store2.py`, `health_store.py`, `stores.py`, `store_base.py` carrying both imports, each refused | 4 |
| 12 H4B prohibitions × 2 modules (`records.py` **and** `store.py`), each still refused | 24 |
| the fixture is removed | 1 |

The seven spellings include the relative form, an aliased relative form,
`from ..common import immutable_store` (which resolves to `tools.common` and is
therefore refused **even in the store**), the absolute form, `import
tools.common.immutable_store`, its aliased form, and a deeper relative form —
so aliases and spellings are covered, not just the one form the store happens
to use.

**The second assertion is a real positive control, not a repeat.** That the
fixture scans clean is only meaningful if the fixture actually exercises the
permission — a copy that silently failed would also scan clean. So the
fixture's `store.py` is asserted to really carry both authorised imports. My
first version of this check re-ran the identical scan and was strictly implied
by the line above it; it was replaced.

**H4B is preserved, and now tested against the store too.** `tools.trust`,
`tools.fabric`, `tools.capability`, `tools.collectors`, `importlib`,
`import_module`, `__import__`, `eval`, `exec`, an unapproved
`tools.common.secrets` and a bare `from ..common import anything_else` are all
still refused — asserted in `records.py` **and** in `store.py`, because the
store having one authorisation must not mean it has any others.

---

## 4. Mutation testing

**26 mutations. 23 caught; 3 shown to be redundancy rather than gaps.**

First pass: 20 mutations, **16 caught, 4 not**. One was a real gap (§2.3,
closed). The other three were pin removals, re-examined below. Six further
mutations were then run, all caught.

**Caught — Correction 1:** `records` fullmatch→match (14 assertions, six of
them in the identifier-sequence path);
identifier rejection removed entirely (140); the identifier check accepting a
`.strip()`ed value (52); a pattern losing its anchors (1, after §2.3); a
pattern widening its digit count (3); a pattern's prefix changed (72);
`store.path_for` fullmatch→match (3); `store.validate` fullmatch→match (1).

**Caught — Correction 2:** permission widened back to the package (5);
rescoped to an evaluator (4); a second module granted it (7); widened to all of
`tools.common` (4); **the file scope ignored inside the scan (34)**; the
serialiser exception rescoped to an evaluator (3); the storage-name exemption
widened (1); an evaluator acquiring the approved store import (4); an evaluator
acquiring `import yaml` (2); an evaluator acquiring a Trust import (2); the
store acquiring a *second* cross-package import (2).

### The three that were not caught alone, and what they actually mean

Removing the content pin, the shape pin, or the file-half pin individually
changes no behaviour: the enforcement is the AST scan and the fixture battery,
and weakening a pin while leaving the permitted set correct leaves nothing to
detect. **The meaningful form is to weaken the pins *and* commit the
violation**, which was then measured:

| Mutation | Result |
|---|---|
| all three pins removed **and** permission widened to the package | **CAUGHT** — 2 assertions; the store's own import is refused, because an unscoped entry permits nothing |
| all three pins removed **and** permission rescoped to an evaluator | **CAUGHT** — 2 assertions; the store loses its authorisation |
| all three pins removed **and** a second module granted the permission | **CAUGHT** — 5 assertions; `PERMITTED in records.py: from ..common.immutable_store import ImmutableStore` |

So the pins are **defence in depth over the battery, not the sole detector** —
which is the honest description, and it is why the battery was written rather
than the pins alone being trusted. The pins remain explicit and independently
testable, as the brief requires: each fails on its own when the permitted set
changes, which the first-pass results above show.

As in H6, no guard can catch an arbitrary edit to its own enforcement code.
What does hold is that no permission, exemption or forbidden identifier can be
changed in a single constant that both the enforcement and a pin read.

---

## 5. Regressions and full suite

| Suite | Before H6A | After H6A | Result |
|---|---|---|---|
| `test-health-records.sh` | 694 | **819** | PASS |
| `test-capability-health.sh` | 553 | **647** | PASS |
| `test-health-store.sh` | 191 | **210** | PASS |
| `test-health-conditions.sh` | 297 | 297 | PASS |
| `test-health-freshness.sh` | 217 | 217 | PASS |
| `test-health-hysteresis.sh` | 206 | 206 | PASS |
| `test-health-binding.sh` | 87 | 87 | PASS |
| `test-capability-health-agreement.sh` | 88 | 88 | PASS |
| `test-capability-fabric.sh` | 538 | 538 | PASS |
| `test-static.sh` | 877 | 877 | PASS |
| `test-docs-static.sh` | 994 | 994 | PASS |
| `test-platform-model.sh` | 1003 | 1003 | PASS |
| `test-fabric-runtime.sh` | 8355 | 8355 | PASS |

**AC 25 preserved:** all **20** AC 25 assertions in `test-fabric-runtime.sh`
pass, including the two barrier self-tests ("the import barrier detects a
forbidden static import", "the dynamic-import barrier detects a forbidden
dynamic import"). H6A changed the Health-outbound guard; the Fabric-inbound
direction is untouched.

**Full suite, on the frozen tree:**

| | executed | passing | failing |
|---|---|---|---|
| baseline before H6A | 159 | 131 | 28 |
| after H6A | **159** | **131** | **28** |

```
newly failing:      (none)
no longer failing:  (none)
identical membership (normalized): YES
production root: stat: cannot statx '/var/lib/kyri/health': No such file or directory
```

Membership was compared by **normalized** suite name — the recorded baseline
file carries the `.sh` suffix and the run records bare names, which is exactly
the artefact that produced a false `identical membership: NO` during H6. The
28 remaining failures are the pre-existing generation-installer and
helper-ceremony debt. **The suite as a whole is not GREEN and is not described
as GREEN.** H6A adds no suite, so the totals are unchanged by design: it
corrects two defects inside suites that already existed.

**The report file itself kept changing after that run started.** It is
untracked markdown and no suite's pass or fail depends on its prose, but rather
than assume that, all **ten** suites that read `docs/` or
`docs/development/reports` were run individually against the final committed
content: `test-docs-static`, `test-static`, `test-developer-experience`,
`test-capability-health`, `test-collector-framework`,
`test-fabric-package-manifest`, `test-capability-execution-coordinator-authority`,
`test-capability-cadm-000001-correction-rehearsal`, `test-fabric-route-preflight`,
`test-fabric-advertisement-preflight`, `test-fabric-admission-dependency-bound`
and `test-fabric-instance-admission-integrity` all pass;
`test-capability-execution-generation11-installer` fails and is one of the 28.

**One measurement discarded.** A full run was started and then abandoned
because the identifier-sequence fixtures of §2.1 landed while it was in
flight, so it was measuring a tree that no longer existed. The tree was frozen
and the run repeated. This is the second time in this increment pair that a
full measurement had to be restarted for the same reason; the rule being
followed is that a full-suite figure is only reported for the exact tree being
committed.

`bash -n` and `shellcheck` are clean on all three touched suites.

---

## 6. Questions resolved and still open

- **Q-H6-4 — RESOLVED.** `_identifier` fullmatches. Parser and store agree,
  asserted directly. Both barriers retained.
- **Q-H6-5 — RESOLVED.** Permissions are `file:module` pairs, scoped to
  `tools/health/store.py`, fail-closed, four pins, 91-assertion demonstration.
- **Q-H6-6 — RESOLVED BY RULING.** `HealthStoreError = StoreError` retained
  unchanged. No code or test touched for this.
- **Still open, unchanged by H6A:** the store remains unexercised by any
  producer; concurrency is proven in-process only; `counts()` is still not
  routed through the directory vetting (H6 §10).

---

## 7. Known risks

- **The anchors are now redundant but retained.** `^...$` inside a
  `fullmatch`ed pattern does nothing. They are kept because the committed
  schema declares them and §2.3 pins the module to the schema, so the two
  cannot diverge — but a future reader may find the redundancy surprising.
- **The fixture battery copies the real modules.** If a Health module were
  added without being added to the battery's victim list
  (`__init__ records errors conditions freshness hysteresis`), it would not be
  exercised by the moved-import cases. The module allowlist is what forces a
  new module to be declared; the victim list is a second place to update.
- **Correction 1 narrows accepted input.** Any caller that was passing an
  identifier with a trailing newline will now be refused. Nothing in the
  repository does — the full suite confirms it — but this is a real contract
  narrowing, which is why it is a corrective increment and not a silent fix.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H6A — resolve Q-H6-4 (full-string identifier matching) and
Q-H6-5 (module-scoped cross-package import permissions). Corrective only.

**Files Changed:**
- `tools/health/records.py` — `_identifier` fullmatches (one condition, plus
  the comment recording why).
- `tests/test-health-records.sh` — 16 extraneous-character shapes × 6
  families, plus reference fields and identifier sequences; the
  module-pattern-to-schema pin.
- `tests/test-capability-health.sh` — permitted set converted to `file:module`
  pairs; per-file `permits()` in the AST scan; four pins; both scans
  root-parameterised; the 91-assertion fixture battery.
- `tests/test-health-store.sh` — the tolerant newline fixture replaced by a
  direct assertion; the parser/store agreement block; `refuses(..., kind=)`.
- `docs/development/reports/eng-0006/2026-10-23-eng-0006-h6a-identifier-and-import-scope.md` — this report.

`tools/health/store.py` is **unchanged**: it already fullmatched, and Q-H6-6
was ruled to retain the existing alias.

**Tests Executed:** the thirteen suites in §5, all passing; RED proven for both
corrections before GREEN; 26 mutations; AC 25; the full validator in §5.

**Commands Run:** `git rev-parse`, `git log`, `git status`, `git diff`;
`bash tests/test-*.sh` individually and across all suites; `bash -n` and
`shellcheck` on the three touched suites; two mutation harnesses.
No push, merge, rebase, tag, or deploy. No write to `/var/lib/kyri`, Fabric or
Trust storage. No production service, credential or permission touched.

**Known Risks:** §7.

**Architecture Decisions:**
1. Corrected at the **one common path** (`_identifier`), not per family.
2. Declared formats, widths, prefixes and error codes unchanged; anchors
   retained and pinned to the schema instead of removed.
3. `subject_id`/`collector_id`/`source_fingerprint` deliberately **out of
   scope** — H2's committed contract leaves them unconstrained.
4. Both the parser and the store fullmatch; the store's barrier is retained
   rather than deleted as now-redundant.
5. Permissions became `file:module` pairs, reusing the shape the serialiser
   exception already had — **no policy redesign**, so no BLOCKED report.
6. Unscoped entries permit nothing (fail-closed), demonstrated behaviourally.
7. Both guard scans root-parameterised so module scope can be *demonstrated*
   on a fixture tree rather than merely asserted on a compliant one.
