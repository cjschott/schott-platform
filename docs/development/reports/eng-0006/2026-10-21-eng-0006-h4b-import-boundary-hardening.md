# ENG-0006-H4B — Health Import Boundary Hardening

**Date:** 2026-10-21
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `2e2e2a34657b0b31ae0498b30274670d6cd18c3a` (H4A, committed, **unpublished and BLOCKED**)
**Increment type:** Corrective. One test guard hardened. **No implementation change.**
**Status:** READY FOR REVIEW

> H4A is preserved as an immutable committed predecessor. This increment adds
> one commit on top of it and rewrites none of its history.

---

## 1. The H4A bypass

H4A's publication gate found that two lines of plain Python defeated the guard
H4A had just added:

```python
_ALIAS = __import__
_TRUST = _ALIAS("tools.trust.models")
```

Placed in `tools/health/freshness.py`, this loads `tools.trust.models` into
`sys.modules` **from inside a Health module** — confirmed by inspecting
`sys.modules`, not inferred — while `test-capability-health.sh` and both
evaluator suites exit 0. `governance-boundaries.md:131` states that Trust and
Health must never reach each other "in either direction". That prohibition was
defeated in fact.

### Root cause

The H4A guard matched **import statements** plus two **callee spellings**:

```python
if name in ("import_module", "__import__"):
```

where `name` came from `ast.Name.id` or `ast.Attribute.attr` **of a `Call`
node**. It tracked no name binding. A bare `__import__` on the right-hand side
of an assignment is a `Name` **load**, not a `Call`, so nothing flagged the
binding; and the later call's callee is `_ALIAS`, which is not in the set. The
guard was trying to recognise a *call shape* when the thing worth recognising
is an *identifier reference*.

A second, independent gap: the banned `eval`/`exec`/`compile`/`__import__` call
checks lived only in the conditions and freshness suites, covering three of the
five approved modules. `errors.py` and `__init__.py` were inspected by nothing.

---

## 2. RED evidence

Reproduced in an isolated disposable checkout — a `git clone`, so that
`/opt/schott-platform/.git` was never touched — at commit `2e2e2a3`.

**Fixture design.** Every fixture is placed inside a module-level function that
is **never called**. It is syntactically valid, fully visible to the AST, and
cannot raise at import time, so a pass can never be mistaken for enforcement
and a failure can never be an incidental runtime exception. This matters: in
H4A's gate, `getattr(__builtins__, "__import__")(...)` *appeared* to be caught,
but all four banned-call regexes miss it — it failed only because
`__builtins__` is a `dict` in an imported module, raising `AttributeError`. That
is a CPython accident, not a control, and the function-body fixture removes the
confusion.

**Fourteen of sixteen dangerous fixtures were admitted by H4A:**

| fixture | H4A |
|---|---|
| `_ALIAS = __import__; _ALIAS("tools.trust.models")` | **admitted** |
| `__import__("tools.trust")` | rejected |
| `eval("1")`, `exec("pass")`, `compile(...)` | rejected (by the *freshness* suite, not the guard) |
| `_e = eval; _e("1")` | **admitted** |
| `_g = exec; _g("pass")` | **admitted** |
| `_h = compile` | **admitted** |
| `getattr(builtins, "__import__")("tools.trust")` | **admitted** |
| `__builtins__["__import__"]("tools.trust")` | **admitted** |
| `builtins.exec` | **admitted** |
| `_l = __import__` (no call) | **admitted** |
| `_m = import_module` (no call) | **admitted** |
| `_n = __import__; _n("tools.trust")` in **`errors.py`** | **admitted** |
| `_p = eval` in **`errors.py`** | **admitted** |
| `_q = __import__; _q("tools.trust")` in **`__init__.py`** | **admitted** |
| `_s = eval` in **`__init__.py`** | **admitted** |

Legitimate controls: `import json` and `from datetime import timezone` were
correctly permitted throughout.

---

## 3. The correction

`tests/test-capability-health.sh` only. **No implementation file was touched.**
The H4A `Import`, `ImportFrom` and `Call` enforcement is **retained** — nothing
was weakened or replaced — and identifier enforcement is added beside it.

```bash
HEALTH_FORBIDDEN_NAMES=(__import__ import_module eval exec compile
                        builtins __builtins__ globals locals vars)
HEALTH_FORBIDDEN_ATTRS=(__import__ import_module eval exec)
```

```python
elif isinstance(node, ast.Name):
    if node.id in forbidden_names: ...
elif isinstance(node, ast.Attribute):
    if node.attr in forbidden_attrs: ...
```

`ast.walk` visits every node, so a `Name` serving as a call's callee is seen
here too. The rule therefore fires in **any** expression context — assignment,
call, attribute root, subscript root, argument — rather than only where a call
is syntactically recognisable.

`globals`, `locals` and `vars` were added beyond the brief's seven because they
are the cheap route back to `__builtins__`
(`globals()["__builtins__"]["__import__"]`), and a usage census showed all three
absent from the package, so adding them costs nothing.

### Two false-positive traps, found by census before implementing

A broad rule here would have broken working code. A census of every `Name` and
`Attribute` node in the package found:

| identifier | as `Name` | as `Attribute` | disposition |
|---|---|---|---|
| `compile` | 0 | **7** | all `re.compile(...)` — **legitimate** |
| `getattr` | **2** | 0 | `records.py:947`, `:965`, citation validation — **legitimate** |

So **`compile` is forbidden as a `Name` only and deliberately omitted from the
attribute list**, and that loses nothing: the builtin `compile` is unreachable
as an attribute without a root named `builtins` or `__builtins__`, both
forbidden as names. `re.compile` keeps working. **`getattr` stays permitted**
for the mirror-image reason — it is in legitimate use, and
`getattr(builtins, "eval")` is already caught by its root.

### Coverage across all five approved modules

The scan already globbed `tools/health/**.py`, but nothing *proved* it. Five
assertions now iterate `HEALTH_MODULE_ALLOWLIST` and require each approved
module to appear in the scanned set, so the `errors.py` / `__init__.py` gap
cannot reopen silently.

### The policy itself is pinned

Without this, deleting a name from the sets would retire a prohibition and
every suite would still pass — which is how the H4A gap survived its own
review. Sixteen assertions now require each forbidden name and attribute to be
present, require `compile` to stay **out** of the attribute list, and require
the permitted cross-plane set to be **empty**.

---

## 4. Negative tests

**32 fixtures: 26 rejected, 6 permitted, all as intended.**

> **CORRECTION, ENG-0006-H5C.** This section first read "31 fixtures: 25
> rejected, 6 permitted". The harness runs **32 — 26 rejected and 6
> permitted**; the total and the rejected count were each understated by one.
> Censused by group: 1 alias bypass + 4 direct builtins + 5 bare aliases + 3
> getattr/subscript/attribute + 3 globals/vars/locals + 5 per-module + 5
> retained import coverage = 26 rejected, plus 6 permitted. Every fixture
> behaved as intended both before and after the recount, so no verdict
> changes.

| group | result |
|---|---|
| the original two-line bypass | **rejected** |
| direct `__import__`, `eval`, `exec`, `compile` calls | rejected |
| bare aliases `_e = eval`, `_f = exec`, `_g = compile`, `_h = __import__`, `_i = import_module` | rejected |
| `getattr(builtins, "__import__")(...)`, `__builtins__["__import__"](...)`, `builtins.exec` | rejected |
| `globals()["__builtins__"]["__import__"](...)`, `vars()`, `locals()` | rejected |
| the alias bypass in **each** of the five approved modules | rejected, 5/5 |
| H4A's coverage retained: `import tools.trust`, `from tools.observation import …`, `from ..trust import …`, `from .. import fabric`, `import importlib` | rejected |
| `import json`, `from datetime import timezone`, **`import re; re.compile("x")`**, **`getattr(object, "__doc__", None)`**, `from . import errors`, `from .records import KINDS` | **permitted** |

### Mutation tests

**Policy mutations — all six detected by the pin:**

| mutation | detected |
|---|---|
| drop `__import__` from the Name set | **yes** |
| drop `eval` from the Name set | **yes** |
| empty the Name set entirely | **yes** |
| drop `.__import__` from the Attribute set | **yes** |
| add `compile` to the Attribute set (would break `re.compile`) | **yes** |
| pre-authorise a cross-plane permission | **yes** |

**Enforcement mutations — every clause load-bearing:**

| mutation | result |
|---|---|
| drop the `Name` clause | `_x = __import__; _x("tools.trust")` **admitted** |
| drop the `Attribute` clause | `_x = object.__import__` **admitted** |
| scan only the evaluator modules | the five coverage assertions **fail** |

The attribute mutation needed a sharper fixture than the first attempt:
`builtins.exec` is caught twice over, because `builtins` is a forbidden *name*,
so the clause looked dead. `object.__import__` has a root the name list does not
forbid, and is caught **only** by the attribute clause.

---

## 5. Boundary limitations

**What the guard guarantees.** For each of the five approved modules under
`tools/health`, the committed **source** contains no import of a sibling plane
in absolute, aliased, submodule or relative form; no import of `importlib`; and
no reference, in any expression context, to `__import__`, `import_module`,
`eval`, `exec`, `compile`, `builtins`, `__builtins__`, `globals`, `locals` or
`vars`.

**What it is not.** It is **not a Python sandbox** and not a defence against
arbitrary dynamically generated code. It is a static source boundary: a
tripwire against drift, enforced at review time, not at runtime.

**Remaining bypass classes**, named rather than described as impossible:

| class | status | why it is not closed here |
|---|---|---|
| `import sys; sys.modules["tools.trust"]` | **not rejected** | It **cannot initiate a load** — verified: with nothing else importing it, `sys.modules["tools.trust"]` raises `KeyError`. It can only piggyback on an import made elsewhere in the same process, so it does not defeat an *import* boundary. Forbidding `sys` outright would be over-broad for a package that may legitimately need it later. |
| `().__class__.__bases__[0].__subclasses__()` | **not rejected** | Deep introspection reaches arbitrary classes without naming any forbidden identifier. Closing it would mean forbidding `__class__`, `__bases__` and `__subclasses__`, and effecting an import from there takes substantial further work. Unmistakably evasive rather than low-complexity. |
| `getattr(object, "__" + "subclasses__")` | **not rejected** | Same class: a name built from string fragments is invisible to an identifier check. Requires a different control — code review, or a runtime import hook. |
| `__loader__.load_module("tools.trust.models")` | **not rejected** | **ENG-0006-H5C, tested.** A module's own loader is bound to its own name: the call raises `ImportError: loader for tools.health.freshness cannot handle tools.trust.models`, and `tools.trust.models` does not appear in `sys.modules` afterwards. Observed behaviour only — this is not a claim of Python runtime isolation, and a differently-obtained loader is a different question. |
| `__spec__.loader.load_module("tools.trust.models")` | **not rejected** | **ENG-0006-H5C, tested.** Identical observed behaviour and identical `ImportError`, for the same reason: `__spec__.loader` is the same object bound to the same name. Observed behaviour only. |
| `open()` and filesystem reads of another plane's store | **out of scope** | Not an import. Governed separately by store roots, filesystem ownership and the `governance-boundaries.md` direction matrix. |

> **ADDED IN ENG-0006-H5C.** The two loader rows were found during H5's
> semantic audit and were absent from this report as published. They are
> recorded as **not rejected by the guard**, with the observed runtime
> behaviour stated as observation rather than as a guarantee: the guard is a
> static source boundary, and nothing here claims it sandboxes a Python
> process.

**No low-complexity bypass of the claimed boundary remains.** The one remnant
that looks innocuous — `sys.modules[...]` — provably cannot bring another plane
into the process; the rest require deliberate introspection that no engineer
writes by accident. That is why this increment reports REVIEW_REQUIRED rather
than BLOCKED, and the limitations are stated above rather than implied.

---

## 6. Validation

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-records.sh` | 0 | 694 | 0 |
| `test-health-conditions.sh` | 0 | 294 | 0 |
| `test-health-freshness.sh` | 0 | 217 | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | **523** | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-static.sh` | 0 | 875 | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

**AC 25 preserved** — 20 assertions.

**Added assertions accounted for.** Exactly one suite moves:
`test-capability-health.sh` **502 → 523, +21**, which is 5 scan-coverage
assertions (one per approved module) plus 16 policy-pin assertions (10 forbidden
names, 4 forbidden attributes, `compile` kept out of the attribute list, and the
empty cross-plane permitted set). Every other suite reports exactly the total it
reported at H4A, which is the evidence that no implementation behaviour changed.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| at H4A (`2e2e2a3`) | 157 | 129 | 28 |
| **with H4B** | **157** | **129** | **28** |

- newly failing: **none**; no longer failing: **none**
- **identical failing membership: YES**, compared name-by-name

No suite was added, so the count stays at 157. The validator remains red on the
same 28 pre-existing failures; none was repaired and none introduced.

---

## 7. Scope

**Two files:**

| file | change |
|---|---|
| `tests/test-capability-health.sh` | the identifier enforcement, the five-module scan proof, and the policy pin |
| this report | **new** |

**Verified unchanged, not merely asserted** — all five approved modules are
**byte-identical** to `2e2e2a3`: `records.py`, `conditions.py`, `freshness.py`,
`errors.py`, `__init__.py`. `__all__` still holds the same 16 names. The four
closed module allowlists, the H4A `Import`/`ImportFrom`/`Call` enforcement, the
original plane-import `grep`, the Health→Fabric and Fabric→Health protections
and AC 25 are all untouched. No new cross-plane permission was added — the
permitted set is empty and an assertion now requires it to stay that way.

No schema, ADR, ontology, Fabric, Capability Runtime, Trust, collector,
provisioning, validation-driver or CI change. No new Health capability, no new
refusal code, no new module.

**Production isolation:** `/var/lib/kyri` empty, **0** `CH*` records, no
listener, daemon, collector or heartbeat receiver, no Trust/Fabric/Capability
mutation, no root operation, no deployment. The RED and mutation work ran in a
disposable `git clone`; `/opt/schott-platform/.git` was never touched.

---

## 8. Carried forward

**Closed by this increment:** the H4A alias bypass, the `errors.py` /
`__init__.py` coverage gap, and the absence of any check on the guard's own
policy.

**Open, untouched:** Q-H4-1 (no aging threshold declared for Health — the CHENV
recommendation stands), Q-H4-2, Q-H4-3, Q-H3-1 through Q-H3-4 with **Q-H3-3
still required before H9**, Q-H2A-2, Q-H2A-3, Q-H2-1, Q-H2-2, the absence of
any general unknown-key rejection in the schemas, and **D1–D7** — **D5 still
blocks heartbeat receiving** and **D6 remains deferred and actively refused**.

**Recorded forward obligation, unchanged from H4A:** when H6 needs
`tools.common` and H13 needs `tools.capability.records`, each must add its name
to `HEALTH_PERMITTED_PLANE_IMPORTS` **in its own increment**, with justification
and negative tests. The policy pin now makes that impossible to do quietly: the
empty-set assertion fails the moment a permission is added without changing it.

### What this increment did not do

No implementation change of any kind, no hysteresis evaluator (A5/H5), no
derivation, no store, no collector, no heartbeat receiver, no Fabric
integration, no new cross-plane permission, and no resolution of any deferred
question.
