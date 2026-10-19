# ENG-0006-H4A — Cross-Plane Import Guard and Documentation Corrections

**Date:** 2026-10-20
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `2bed9d336664596ed7f13140210ce8f50ac23f71` (H4, published)
**Increment type:** Corrective. One test guard strengthened, three documents corrected. **No evaluator behaviour changed.**
**Status:** READY FOR REVIEW

---

## 1. Why

H4's published-source review found that a claim in the H4 report was false: it
said a Health module importing `tools.observation` "is a cross-plane import
that `test-capability-health.sh` refuses by name". It does not. Probing the
guard turned up something larger than a missing package name.

---

## 2. The dependency policy, from committed authority

The brief is explicit that not every sibling is forbidden, and the committed
plan proves it. **Two Health dependencies are already foreseen:**

| dependency | authority | increment |
|---|---|---|
| `tools.common` — `ImmutableStore`, the declared base for `HealthStore` | ENG-0006-D `:100`, `:187`, `:504` | **H6** |
| `tools.capability.records` — `OUTCOME_CLASSES`, read-only | ENG-0006-D `:261` | **H13 / E1** |

And the committed adapter pattern **does** import across planes:
`tools/fabric/trust_adapter.py:35-39` reads
`from ..trust.identifiers import …`, `from ..trust.models import …`,
`from ..trust.query import …`. So a blanket "Health may import no sibling"
rule would have to be weakened twice later — at H6 and at H13 — which is
exactly the pattern this project treats as a defect.

**Forbidden, by committed authority:**

| boundary | rule | source |
|---|---|---|
| Health → Trust | "Trust reads or writes Health: **Never**, in either direction" | `governance-boundaries.md:131` |
| Health → Fabric | record access only through read-only adapters; no write path, ever | `governance-boundaries.md:128`; ENG-0006-D `:494` |
| Capability ↔ Health | "none, in either direction from the Capability side" | ENG-0006-D `:497` |
| everything else under `tools/` | not declared, therefore not permitted | — |

So the rule is an **allowlist, not a denylist**, and today that allowlist is
**empty**. Neither foreseen dependency is pre-authorised: each must arrive with
its own increment, justification and negative tests, exactly as the module
allowlist has done at H1B, H3A and H4. A denylist would silently permit the
next package anybody adds under `tools/`.

---

## 3. RED — what the guard actually did

`test-capability-health.sh` as published at H4 ran one `grep`:

```
^[[:space:]]*(import|from)[[:space:]]+tools\.(fabric|capability|trust|collectors)\b
```

Sixteen import forms were injected into `tools/health/freshness.py`, one at a
time, in a clean sandbox. **Eleven were admitted:**

| form | H4 guard |
|---|---|
| `import tools.observation` | **admitted** |
| `from tools.observation import confidence` | **admitted** |
| `import tools.observation as obs` | **admitted** |
| `from tools.observation.confidence import assess_freshness` | **admitted** |
| `import tools.common` | **admitted** |
| `from tools.common import immutable_store` | **admitted** |
| `import tools.integrity` | **admitted** |
| `import tools.experience` | **admitted** |
| `import tools.occurrence` | **admitted** |
| `import tools.platform_model` | **admitted** |
| `import tools.provisioning` | **admitted** |
| `import tools.fabric` | rejected |
| `from tools.trust import models` | rejected |
| **`from ..trust import models`** | **admitted** |
| **`from ..fabric import selection`** | **admitted** |
| `from ..observation import confidence` | **admitted** |

**The serious finding is the last three.** The guard named `tools.trust` and
`tools.fabric` and matched only the absolute form, so **writing `..trust`
instead of `tools.trust` bypassed the protection entirely** — and `..trust` is
precisely the form the committed adapter precedent uses. The gap was never
"seven packages are missing from a list"; it was that the rule could be stepped
around in one character.

Also admitted: `import importlib`, the dynamic-import route.

### The asymmetry this exposed

The other two sides of the same barrier already do this correctly, and they are
the precedent followed here:

- `tests/test-capability-runtime.sh:143` forbids **both** `"tools.health"` and
  `"..health"` by name.
- AC 25 in `tests/test-fabric-runtime.sh:12135-12138` walks the **AST** for
  relative imports, and `:12140+` for dynamic ones.

The Health-outbound direction was the weakest of the three. It is now the
strictest.

---

## 4. The correction

`tests/test-capability-health.sh` only. The existing `grep` is **kept** — it
was not weakened — and an AST check is added beside it.

For every `*.py` under `tools/health`, the check parses the module and walks
every `Import`, `ImportFrom` and `Call` node:

| node | rejected when |
|---|---|
| `Import` | `alias.name` is `tools` or starts `tools.`, and is not in the permitted set — covers `import tools.X`, `import tools.X.Y` and `import tools.X as Z`, because the alias does not change `alias.name` |
| `Import` | `alias.name` is `importlib` or a submodule of it |
| `ImportFrom`, `level == 0` | `module` is `tools` or starts `tools.` — covers `from tools import X` and `from tools.X.Y import Z` |
| `ImportFrom`, `level == 0` | `module` is `importlib` or starts `importlib.` |
| `ImportFrom`, `level >= 2` | resolves outside the package — covers `from ..trust import X`, `from ..common.immutable_store import Y` and `from .. import trust` |
| `Call` | the callee is named `import_module` or `__import__` |

`level == 1` is **permitted**: that is `from . import errors` and
`from .records import …`, which stay inside the package. The rule is about
leaving `tools/health`, not about importing.

`HEALTH_PERMITTED_PLANE_IMPORTS` is declared empty, compared by prefix so that
permitting `tools.common` later would also permit `tools.common.immutable_store`
without permitting `tools.commonwealth`.

**Nothing else changed.** The four closed module allowlists are untouched, as
are the Health→Fabric and Fabric→Health protections and AC 25.

---

## 5. GREEN — the new rule, measured

**Forbidden forms, all rejected.** All eleven sibling packages in absolute
form; `from`-import, submodule, alias and `from tools import X` forms; all five
relative forms including the two the old guard let through; and both dynamic
forms. **24 of 24 rejected.**

**Permitted forms, all still accepted:** `from datetime import timezone`,
`import re`, `from decimal import Decimal`, `from typing import Optional`,
`from . import errors as E2`, `from .records import KINDS`,
`from .conditions import CONDITION_OUTCOMES`. **7 of 7 accepted** — the guard
rejects leaving the package, not importing.

### Mutation-testing the guard itself

Each clause was removed in turn and a form only that clause catches was
injected. **Every clause is load-bearing:**

| clause removed | result |
|---|---|
| the relative-import clause (`level >= 2`) | **weakened** — `from ..trust import models` admitted |
| the absolute `ImportFrom` clause | **weakened** — `from tools.observation import confidence` admitted |
| the plain `Import` clause | **weakened** — `import tools.observation` admitted |
| the dynamic `importlib` clause | **weakened** — `import importlib` admitted |
| the `import_module()`/`__import__()` call clause | **weakened** — `__import__("tools.trust")` admitted |
| pre-authorising `tools.observation` in the permitted set | **weakened** — that import admitted |

The call clause needed a sharper probe than the others: `from importlib import
import_module` is caught twice over, by the `importlib` clause as well, so the
first attempt looked like a dead clause. `__import__("tools.trust")` is the
form **only** the call clause catches, because `__import__` is a builtin
needing no import statement — and with the clause removed, it is admitted.

A seventh mutation shows why the rule is `level >= 2` rather than `level >= 1`:
the broader form rejects all **nine** of the package's own legitimate
Health-local imports. That is the "broad pattern that may accidentally reject
legitimate shared dependencies" the brief warned against, demonstrated rather
than asserted.

---

## 6. Documentation corrections

### The H4 report

1. **The false claim is withdrawn**, quoted verbatim so the record shows what
   was said, with the measured reality beside it and H4A's resolution. The
   Q-H4-1 **decision is unaffected**: its first argument — that copying the
   constant would default a second freshness parameter against the Null Policy
   Rule — stands on its own, and only the supporting claim was wrong.
2. **Three stale mutation counts corrected**: 6 from 14 to **15**, 8 from 7 to
   **11**, 10 from 52 to **48**. The cause is recorded: thirteen of the fifteen
   rows were measured on the first pass and only 9 and 13 were re-measured
   after nine assertions were added, so the table mixed two suite states.
3. **The measurement history is preserved, not erased.** Mutations 9 and 13
   genuinely survived the first pass — that is why those assertions exist — and
   the superseded figures for 6, 8 and 10 were genuine measurements of a suite
   that no longer exists. Every verdict was and remains DETECTED.
4. **The scope count is corrected from eleven to twelve**, which was a header
   miscount: the table already listed twelve rows including the report itself.

### `tools/health/__init__.py`

The docstring described "one pure evaluator" and ENG-0006-H1 through H3. It now
describes all four modules, both evaluators, `select_observations`, the
one-way dependency in both directions (evaluators import `records`, `records`
imports neither, and the evaluators do not import each other), and why `aging`
is reported only when a caller supplies a threshold.

**Imports and exports are provably unchanged:** the module's AST is identical
after removing the docstring, and `__all__` still holds the same 16 names.

---

## 7. Validation

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-records.sh` | 0 | 694 | 0 |
| `test-health-conditions.sh` | 0 | 294 | 0 |
| `test-health-freshness.sh` | 0 | 217 | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | **502** | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-static.sh` | 0 | 875 | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

**AC 25 preserved** — 20 assertions.

**Only one number moved**, and it moved by one: `test-capability-health.sh`
501 → 502, the new AST assertion. Every other suite reports exactly the total it
reported at H4, which is the evidence that no evaluator behaviour changed.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| at H4 (`2bed9d3`) | 157 | 129 | 28 |
| **with H4A** | **157** | **129** | **28** |

- newly failing: **none**; no longer failing: **none**
- **identical failing membership: YES**, compared name-by-name

No suite was added, so the count stays at 157. The validator remains red on the
same 28 pre-existing failures; none was repaired and none introduced.

---

## 8. Scope, and what did not change

**Four files:**

| file | change |
|---|---|
| `tests/test-capability-health.sh` | +95; the AST import guard, beside the retained `grep` |
| `tools/health/__init__.py` | +26/−13; **docstring only** |
| `docs/.../2026-10-19-eng-0006-h4-freshness-evaluator.md` | +42/−7; the four errata |
| this report | **new** |

**Verified unchanged, not merely asserted:**

| | |
|---|---|
| `tools/health/records.py` | **byte-identical** to `2bed9d3` |
| `tools/health/conditions.py` | **byte-identical** |
| `tools/health/freshness.py` | **byte-identical** |
| `tools/health/errors.py` | **byte-identical**, 27 codes |
| `tools/health/__init__.py` | **AST identical** after removing the module docstring; `__all__` still 16 names |
| the four closed module allowlists | untouched; the `HEALTH_MODULE_ALLOWLIST` array is byte-identical and the three `case` guards were not opened at all |
| the original plane-import `grep` | **retained**, not replaced |
| Health→Fabric and Fabric→Health protections, AC 25 | untouched and passing |

No schema, ADR, ontology, Fabric, Capability Runtime, Trust, collector,
provisioning, validation-driver or CI change. No new Health capability, no new
refusal code, no new module, no suite added.

**Production isolation:** `/var/lib/kyri` empty, **0** `CH*` records, no
listener, daemon, collector or heartbeat receiver, no Trust/Fabric/Capability
mutation, no root operation, no deployment.

---

## 9. Carried forward

**Closed by this increment:** the H4 report's false `tools.observation` claim,
its three stale mutation counts, its scope miscount, the stale package
docstring, and the cross-plane import guard gap itself.

**Still open, untouched:**

- **Q-H4-1** no aging threshold is declared anywhere for Health. *The
  recommendation stands: declare an optional threshold on the CHENV dimension
  entry.*
- **Q-H4-2** the review flag on absent evidence — now known to be **explicitly
  specified** by `capability-health-state.schema.yaml:248-250` ("present and
  false otherwise"), with the general standard's `:78` ambiguous and the
  Knowledge plane reading it the other way.
- **Q-H4-3** future-dated observations.
- **Q-H3-1** what `windowed_count` counts; **Q-H3-2**; **Q-H3-3**
  `measured_value` has no declared representation anywhere and H1 does not
  validate it — **still required before H9**; **Q-H3-4**.
- **Q-H2A-2**, **Q-H2A-3**, **Q-H2-1**, **Q-H2-2**.
- The schemas have **no general unknown-key rejection mechanism**.
- **D1–D7** all unresolved. **D5 still blocks heartbeat receiving.** **D6
  remains deferred and actively refused.**

**New, recorded here:** when H6 needs `tools.common` and H13 needs
`tools.capability.records`, each must add its name to
`HEALTH_PERMITTED_PLANE_IMPORTS` **in its own increment**, with the
justification and the negative tests, rather than arriving as a quiet widening.

### What this increment did not do

No evaluator behaviour change of any kind, no hysteresis evaluator (A5/H5), no
derivation, no store, no collector, no heartbeat receiver, no Fabric
integration, and no resolution of any deferred question.
