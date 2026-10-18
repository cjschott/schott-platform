# ENG-0006-H3A — Health Module Boundary Transition

**Date:** 2026-10-18
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `67a445ce68766ab71df52d5015432f8d97764dfb` (H3, published)
**Increment type:** Structural. No behaviour change, by design and by proof.
**Status:** READY FOR REVIEW

---

## 1. Why the boundary was needed

H3 shipped the ADR-0019 condition grammar evaluator **inside
`tools/health/records.py`**, and the H3 report said plainly that this was a
constraint rather than a design choice:

> H1B established a closed allowlist of exactly three files under
> `tools/health` … Creating `tools/health/conditions.py` would fail all four,
> and §7 of the standing rules forbids weakening a guard to obtain a pass. …
> **Here it is merely convenient.** Condition evaluation is not a property of a
> record, and `records.py` is now 1,221 lines holding a record model and an
> evaluator.

The H3 report recommended this transition explicitly, and the reason it is
urgent rather than cosmetic is the shape of what comes next: **A4/H4 is a
freshness evaluator and A5/H5 is a hysteresis evaluator** (ENG-0006-D `:162`
and `:172`; increments `:386-387`). Landing both in `records.py` would produce a module whose name
described a third of its contents, and three evaluators sharing a file with six
record families is a structure nobody would choose deliberately.

The correct order of operations is to move the allowlist and then move the
code — not to weaken a guard, and not to let the file layout be decided by
whichever guard happened to be written first.

---

## 2. Exactly what moved

`tools/health/conditions.py` is new. It holds the H3 block **byte-for-byte**:

| moved | |
|---|---|
| `CONDITION_OUTCOMES`, `UNKNOWN_REASONS` | the two closed vocabularies |
| `_COMPARISONS`, `_CONDITION_FIELDS`, `_AGGREGATION_FIELDS`, `_EVAL` | private tables |
| `ConditionResult` | the frozen result type |
| `_decimal_of`, `_condition_of`, `_aggregation_of`, `_observations_of`, `_usable` | private helpers |
| `evaluate_condition` | the entry point |

**Proof that nothing was edited in transit — two independent checks:**

1. The moved block is **byte-identical**: the 15,098 bytes from the
   `# --- the condition grammar evaluator — ENG-0006-H3` marker to end of file
   at `67a445c` compare equal to the corresponding region of the new module.
2. `tools/health/records.py` is now **byte-identical to its pre-H3 state at
   `f4e6f02`**. The extraction removed exactly what H3 added and nothing
   else — including reverting the `timedelta` import H3 had added for the
   window arithmetic, which is now unused there and would otherwise have been
   left behind as an orphan.

**What stayed in `records.py`:** the six immutable record families, `parse()`,
the per-family validators, `CITATIONS`, `citations_of()` and
`validate_citations()`. Records and subject binding are properties of records;
condition evaluation is not.

**No duplication.** `def evaluate_condition`, `class ConditionResult` and
`CONDITION_OUTCOMES =` each appear exactly once across the package, in
`conditions.py`, and zero times in `records.py`.

---

## 3. Import graph, before and after

**Before (H3):**

```
tools/health/__init__.py ──> records.py ──> errors.py
                                 └─ records.py ALSO held the evaluator
```

**After (H3A):**

```
tools/health/__init__.py ──> conditions.py ──> records.py ──> errors.py
                         └─> records.py ──────────┘  └────────> errors.py
                         └─> errors.py
```

`conditions.py` imports, explicitly and by name:

```python
from . import errors as E
from .records import (AGGREGATIONS, CONDITION_OPERATORS, DIMENSION_UNITS,
                      HealthRecord, _decimal_text, _instant, _whole)
```

**The dependency runs one way, and that is asserted, not just stated.**
`records.py` contains no reference to `conditions` at all — checked both by
`grep` and by a suite assertion over `inspect.getsource(records)`. There is no
circular import and no implicit re-export: nothing uses `import *`, and the
package `__init__` names every symbol it re-exports.

---

## 4. The public import contract is preserved

`tools/health/__init__.py` re-exports the same ten names it did at H3, with
`__all__` unchanged. The suite asserts more than mere presence — it asserts
**object identity**, because an alias that wrapped or copied the evaluator
would be a second implementation to keep in step:

| name | re-exported from | identity asserted |
|---|---|---|
| `evaluate_condition`, `CONDITION_OUTCOMES`, `UNKNOWN_REASONS`, `ConditionResult` | `conditions` | `is` |
| `parse`, `HealthRecord`, `KINDS`, `citations_of`, `validate_citations` | `records` | `is` |
| `HealthRecordError` | `errors` | — |

And the converse: `records` no longer carries `evaluate_condition`,
`ConditionResult`, `CONDITION_OUTCOMES` or `UNKNOWN_REASONS`, each asserted
absent by name.

Any caller written against `tools.health` at H3 is unaffected. A caller that
reached *into* `tools.health.records` for the evaluator would break — there are
none, verified: nothing outside `tools/health` imports the package at all.

---

## 5. The four guard changes

Their enforcement mechanisms were read before editing, because they are not
five copies of one check:

| suite | mechanism | change |
|---|---|---|
| `tests/test-capability-health.sh` | a bash array compared by **exact equality**, plus a temporary-fixture negative battery | array renamed `HEALTH_H1_ALLOWLIST` → `HEALTH_MODULE_ALLOWLIST` and `conditions.py` added; fixture copies it; **six names added to the intruder battery** |
| `tests/test-capability-fabric.sh` | a `case` pattern with exact alternatives | one alternative added |
| `tests/test-static.sh` | a `case` pattern with exact alternatives | one alternative added |
| `tests/test-docs-static.sh` | a `case` pattern with exact alternatives | one alternative added |

**One name was added to four closed lists. No rule was relaxed.** All four
still compare by exact equality, so a prefix or substring rule has not crept
in. Nothing else about any of the four changed: the eight forbidden
runtime-package names in `test-static.sh`, the fabric-adjacent prohibitions in
`test-capability-fabric.sh`, and the package-wide **non-operational battery**
in `test-capability-health.sh` are untouched.

That battery is the broader invariant, and it was checked against the new
module rather than assumed to still hold: **0** executable files, **0**
interpreter lines, no `__main__.py`, **0** files importing `socket`,
`subprocess`, `requests`, `urllib`, `http`, `asyncio`, `threading`,
`multiprocessing`, `sqlite3` or `yaml`, **0** clock calls in `conditions.py`,
and **0** files importing `tools.fabric` or `tools.capability`.

### Negative guard tests

**In-suite**, against a temporary fixture and never the real package — the
battery grew from 11 intruders to **17**, with the new names chosen
specifically to catch a prefix rule: `conditions_v2.py`, `conditions.pyc`,
`conditions_evaluator.py`, `conditions_store.py`, `xconditions.py`, and a
directory named `conditions`. All 17 rejected, plus a nested unapproved
subpackage.

**Empirically**, in a real `git clone` of the H3A tree — because a guard only
ever run against a compliant tree has not been shown to reject anything:

| intruder | capability-health | capability-fabric | static | docs-static |
|---|---|---|---|---|
| `store.py` | rejected | rejected | rejected | rejected |
| `conditions_v2.py` | rejected | rejected | rejected | rejected |
| `evaluator.py` | rejected | rejected | rejected | rejected |
| `execution/launch.py` | rejected | rejected | rejected | rejected |

All four guards exit 0 on the compliant H3A tree and exit 1 on every intruder.
**Permission was not broadened to arbitrary new Health modules.**

---

## 6. Behavioural equivalence

### Differential proof against the pre-extraction evaluator

The H3 evaluator was reconstructed from `67a445c` into a separate `legacy`
package and run **side by side** with the extracted one over a generated input
matrix: 4 dimensions × 3 unit spellings × 67 conditions × 9 aggregations ×
5 freshness policies × 7 observation subsets, where the subsets include a
reversed ordering and the conditions and aggregations include malformed and
forbidden forms.

| | |
|---|---|
| input combinations compared | **253,260** |
| differences | **0** |

The comparison is on the full result, not just the verdict: `outcome`,
`aggregation`, `observation_ids`, `count` and `unknown_reason` on success, and
on failure the exception type together with its **`code`, `field` and
`detail`**. So the controlled refusal vocabulary and every refusal detail are
proven unchanged, not merely the happy path.

That covers every item §4 asks for: operator and aggregation sets, decimal
semantics, all three outcomes, refusal codes and details, observation ordering
and tie-breaking, window boundaries, minimum samples, and freshness-policy
handling — each of which the matrix exercises and none of which differs.

### The existing H3 suite

`tests/test-health-conditions.sh` ran **unchanged in substance**: every
assertion present at H3 is present now, none was weakened or deleted, and the
count rose **280 → 294** purely by addition.

Four adjustments were required, all because the evaluator's module path
changed, and three of them make the suite **stronger**:

1. `from tools.health import conditions as C`, and the evaluator is looked up
   on `C`. Unavoidable: the function is no longer an attribute of `records`.
2. **The non-operational source greps now cover BOTH modules**
   (`inspect.getsource(C) + inspect.getsource(H)`) rather than whichever module
   the evaluator happens to live in. Stronger: moving code between the two
   modules can no longer move it out of the scope of the clock, I/O and
   dynamic-execution checks.
3. **The banned-attribute checks now cover both modules and the package**,
   where before they covered one module. Stronger.
4. `import inspect` moved from mid-file to the top block, because the new
   identity assertions use it earlier. Cosmetic.

Fourteen new assertions were added: object identity of every re-export, the
absence of each moved name from `records`, and the one-way dependency.

---

## 7. Validation

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-conditions.sh` | 0 | **294** | 0 |
| `test-health-records.sh` | 0 | 694 | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | **494** | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-static.sh` | 0 | 874 | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

**AC 25 preserved** — 20 assertions, including "no fabric module imports the
health package".

**Assertion-count changes accounted for.** Two suites moved, both by addition:
`test-health-conditions.sh` 280 → 294 (the boundary assertions of §6), and
`test-capability-health.sh` 487 → 494 (six new intruders in the negative
battery, plus the fourth approved module now checked present). Every other
suite reports exactly the totals it did at H3 — notably
`test-health-records.sh` unchanged at **694**, which is the evidence that
moving code out of `records.py` disturbed none of its record-model behaviour.

No suite was added, so the suite count stays at 156.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| at H3 (`67a445c`) | 156 | 128 | 28 |
| **with H3A** | **156** | **128** | **28** |

- newly failing: **none**
- no longer failing: **none**
- **identical failing membership: YES**, compared name-by-name

**The full validator remains red** on the same 28 pre-existing failures,
dominated by the generation installer and helper-ceremony suites carrying the
known hard-coded `REPOSITORY="/opt/schott-platform"` provisioning defect. No
baseline failure was repaired and none was introduced. A structural transition
that changed no behaviour should move no number, and it moved none.

---

## 8. Scope and production isolation

**Nine files — seven modified, two new:**

| file | change |
|---|---|
| `tools/health/conditions.py` | **new**, 335 lines; the evaluator, byte-identical |
| `tools/health/records.py` | −306/+1; back to its pre-H3 state exactly |
| `tools/health/__init__.py` | +9/−6; re-export split across two modules |
| `tests/test-health-conditions.sh` | +37/−12; §6's four adjustments and 14 new assertions |
| `tests/test-capability-health.sh` | +21/−10; allowlist entry, fixture copy, six intruders |
| `tests/test-capability-fabric.sh` | +3/−3; one `case` alternative |
| `tests/test-static.sh` | +3/−3; one `case` alternative |
| `tests/test-docs-static.sh` | +3/−3; one `case` alternative |
| this report | **new** |

**Not touched:** `tools/health/errors.py` (byte-identical, 27 codes), every
schema, every ADR, the ontology, the Fabric, the Capability Runtime, Trust,
collectors, provisioning, `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml` — no suite was added or removed, so no registration
changed.

**Production isolation:**

| check | result |
|---|---|
| `/var/lib/kyri/health` | **absent** |
| `CH*` records under `/var/lib` | **0** |
| Health listener or daemon | **0** |
| Production Fabric, Trust or Capability mutation | **none** |
| Root operations | **none** — no `sudo` invoked |
| Deployment | **none** |

No Health record is produced, consumed, stored or read by anything, and nothing
outside `tools/health` imports the package. The clone-based guard probes and the
differential equivalence run targeted scratchpad copies, never the working
tree.

---

## 9. Carried forward, unresolved

Unchanged by this increment, which added no behaviour and answered no open
question:

- **Q-H3-1** what `windowed_count` counts; **Q-H3-2** future-dated
  observations; **Q-H3-3** `measured_value` has no declared representation
  anywhere and H1 does not validate it — **still required before H9**;
  **Q-H3-4** subject agreement enforced in the evaluator.
- **Q-H2A-2** withheld publication authority; **Q-H2A-3** evidence-list
  cardinality; **Q-H2-1** the `EVALUATED_AGAINST` annotation; **Q-H2-2** the
  CHDEG state-citation ambiguity.
- The schema has **no general unknown-key rejection mechanism**.
- **D1–D7** all unresolved. **D5 still blocks heartbeat receiving.** **D6
  remains deferred and actively refused.**

**The H3 report's module-placement recommendation is now closed** — it is what
this increment implemented.

### What this increment did *not* do

No freshness evaluator (A4/H4), no hysteresis evaluator (A5/H5), no state
derivation (D1c/H10), no percentile support, no new refusal code, no schema
change, and no new Health capability of any kind. The allowlist was moved by
exactly one name; permission was not broadened to arbitrary new modules.
