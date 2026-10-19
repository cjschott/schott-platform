# ENG-0006-H4 — Freshness Evaluator

**Date:** 2026-10-19
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `7114f6375ba395b5edc5f4ba13e0db757805fe45` (H3A, published)
**Component:** A4 from the committed ENG-0006-D plan, and only A4.
**Status:** READY FOR REVIEW

---

## 1. Normative authority

| Source | What it fixes |
|---|---|
| `confidence-freshness-standard.md:57-62` | the four states, and no others: `current`, `aging`, `stale`, `unknown` |
| `confidence-freshness-standard.md:64-70` | knowledge age is measured from the **newest** supporting evidence, "because the oldest record in a set says nothing useful" |
| `confidence-freshness-standard.md:72-78` | the Null Policy Rule: a null policy is `unknown` with `review_required: true`, never a default maximum age; "the freshness of nothing is `unknown`, never `stale`" |
| `ADR-0013:142-147` | Health "reuses the existing four states" and the Null Policy Rule; "a dimension with no declared policy produces `unknown`, never a default maximum age" |
| `capability-health-state.schema.yaml:87-100` | the two-freshness separation: `stored_freshness: freshness-at-evaluated-at`, `stored_freshness_authoritative_for_eligibility: false`, `freshness_recomputed_at_use: true` |
| `docs/health/unknown-and-freshness.md:95-112` | "A stored `freshness: current` never remains operationally current"; recompute from each observation's `observed_at`, the dimension's policy and the caller's instant |
| `docs/health/unknown-and-freshness.md:120-126` | the review flag is enumerated for a null policy, `insufficient-policy`, or contradicting sources, "with its written reason naming **which** gap" |
| `docs/health/unknown-and-freshness.md:132-138` | freshness is per dimension; "collapsing them to a single age would hide whichever dimension stopped reporting" |
| `capability-health-envelope.schema.yaml:124-126` | `freshness_policy_seconds` per dimension; "Null is permitted… It must never be defaulted to a number" |
| `capability-health-observation.schema.yaml:110-113`, `:135-139` | the three collection statuses and the four freshness values |
| ENG-0006-D `:162-170` | component A4's purpose, in/out, failure modes and required tests |
| ENG-0006-D `:560` | H4's required negative tests |

---

## 2. The freshness contract

Two keyword-only entry points in the new `tools/health/freshness.py`:

```python
evaluate_freshness(*, dimension, freshness_policy_seconds, observations,
                   evaluated_at, aging_threshold_seconds=None) -> FreshnessResult

evaluate_envelope_freshness(*, dimensions, observations, evaluated_at,
                            aging_thresholds=None) -> Mapping[str, FreshnessResult]
```

`FreshnessResult` is frozen and carries `state`, `age_seconds`,
`policy_seconds`, `aging_threshold_seconds`, `review_required`, `reason` and
`observation_id` — the last so an operator can re-check which observation the
age was measured from.

Measured behaviour:

| case | state | age | review_required | reason |
|---|---|---|---|---|
| age 59, policy 60 | `current` | 59 | false | — |
| **age 60, policy 60** (at the limit) | **`current`** | 60 | false | — |
| **age 61, policy 60** (one past) | **`stale`** | 61 | false | — |
| age 45, policy 60, aging threshold 30 | `aging` | 45 | false | — |
| **null policy** | **`unknown`** | 10 | **true** | `null-freshness-policy` |
| no observations | `unknown` | — | false | `no-usable-observation` |
| only a failed collection | `unknown` | — | false | `no-usable-observation` |
| only an unavailable collection | `unknown` | — | false | `no-usable-observation` |
| a future-dated observation | `unknown` | — | false | `no-usable-observation` |
| newest 5s beside an oldest 600s | `current` | **5** | false | — |

**A freshness label is advisory and is not a health state.** `stale` evidence
contributes no subtraction and does not become `healthy`; ageing out of a
problem is not the same as fixing it. Those are ADR-0013's rules for the
deriving layer, and nothing here claims them. The only token shared with the
seven health states is `unknown`, which is the word both vocabularies use.

### The two-freshness separation is enforced, not described

The module **never reads an observation's stored `freshness` field**. A stored
label is a historical fact; a decision must recompute. Asserted behaviourally
across all four stored values in both directions: an observation stored as
`current` but 600s old computes as `stale`, and one stored as `stale` but 5s
old computes as `current` — eight assertions, plus a source check that no
stored-field access exists. A mutation that read the stored label instead of
computing is detected.

---

## 3. Boundary semantics

| boundary | behaviour | authority |
|---|---|---|
| age **exactly** `freshness_policy_seconds` | `current` | ADR-0019 already treats "age within `freshness_policy_seconds`" as inclusive for usability; H3 asserts the same boundary, so the two evaluators agree |
| age one second past the policy | `stale` | `stale` is "older than the policy maximum age" |
| the same boundary at a 1-second policy | `current` at 1s, `stale` at 2s | no special-casing by magnitude |
| a future-dated observation | never establishes freshness; `unknown` | §5, Q-H4-3 |
| a failed or unavailable collection | never establishes freshness | a collection failure concluded nothing about the subject |
| a newer failed collection beside an older measurement | the **older measurement** sets the age | a dead collector must not keep refreshing the clock |

---

## 4. Unknown and indeterminate outcomes

Two reasons, both from a declared closed set, and each names **which** gap:

**`null-freshness-policy`** — `unknown` **with `review_required: true`**. The
age is still reported, because the evidence exists and its age is a fact even
though no policy makes it assessable. Refusing to invent a maximum is the whole
point: a default would convert an unanswered configuration question into a
confident-looking assessment.

**`no-usable-observation`** — `unknown`, `review_required: false`, no age. The
freshness of nothing is unknown, never stale.

### Why absent evidence does not set the review flag — and a divergence

`unknown-and-freshness.md:120-126` enumerates the causes that carry the flag:
"a null freshness policy, … `insufficient-policy`, or … contradicting
sources". Absent evidence is not among them, and ADR-0013 makes `unknown` the
default, inert state. ENG-0006-D `:168` likewise pairs the flag only with the
null policy: "a null policy → `unknown` **with** `review_required: true`; no
evidence → `unknown`, never `stale`."

**This diverges from the platform's other implementation of the same
standard.** `tools/observation/confidence.py:107-116` sets
`review_required=True` for absent evidence. H4 follows the Health plane's own
enumeration rather than the Knowledge plane's code, and the divergence is
recorded as **Q-H4-2** rather than silently resolved either way.

---

## 5. Interpretations taken, recorded for the reviewer

### Q-H4-1 — no aging threshold is declared anywhere for Health

The standard defines `aging` as "past a **warning threshold** but still within
the maximum" (`:60`). **No warning threshold is declared anywhere in Health
authority**: the envelope dimension declares `freshness_policy_seconds` alone,
and `aging` appears only as an enum member in CHOBS `:137` and CHSTATE `:292`
and as a named state in ADR-0013 `:142`. ADR-0013 reuses the four *states*; it
declares no second threshold.

The platform has made this choice once before, in another plane:
`tools/observation/confidence.py:50-52` declares `AGING_THRESHOLD = 0.5`,
"Named rather than inlined so the boundary is reviewable". Copying it here was
rejected for two reasons. It would be **defaulting a second freshness
parameter**, which is precisely what the Null Policy Rule exists to forbid — an
operator writing `freshness_policy_seconds: 60` would start receiving `aging`
at 31 seconds without having asked for it.

> **CORRECTION, ENG-0006-H4A.** This paragraph originally carried a second
> argument: "And it cannot be imported in any case: a Health module importing
> `tools.observation` is a cross-plane import that
> `test-capability-health.sh` refuses by name." **That was false and is
> withdrawn.** The guard as it stood at H4 enumerated
> `tools.(fabric|capability|trust|collectors)` only, so `tools.observation`
> was not refused — and because it matched the *absolute* form by `grep`, the
> relative form `from ..trust import models` walked past even the four
> packages it did name. Measured, not supposed: eleven of the sixteen import
> forms probed were admitted, including `..fabric` and `..trust`.
>
> **The decision this paragraph reaches is unaffected**, because the first
> argument stands on its own: copying the constant would default a second
> freshness parameter, which is what the Null Policy Rule forbids. Only the
> supporting claim was wrong.
>
> ENG-0006-H4A closed the gap with an AST-based allowlist covering absolute,
> aliased, submodule, relative and dynamic import forms across all eleven
> sibling packages. H4's own code was never affected: the Health package
> imports no `tools.*` package at all.

**So the threshold is an explicit caller input with no default, and while none
is supplied `aging` is never reported.** Verified: sweeping ages 0–120 against
a 60s policy with no threshold produces only `current` and `stale`, never
`aging`; supplying `aging_threshold_seconds=30` makes the band appear between
31s and 60s. The result records which threshold it applied, or `None`. A
mutation that invents a half-policy default is detected.

*RECOMMENDATION:* declare an aging threshold on the CHENV dimension entry —
optional, with its absence meaning no aging band — so the fourth state becomes
reachable by declaration rather than by an implementer's constant.

### Q-H4-2 — the review flag on absent evidence

See §4. Health's enumeration and D both exclude it; the Knowledge plane's
released implementation includes it. H4 follows Health. A reviewer may prefer
the two implementations agree.

### Q-H4-3 — future-dated observations

No rule is declared. H4 excludes them, consistently with H3 (Q-H3-2), because
evidence recorded after the moment an assessment was made cannot support it.
This **diverges from `tools/observation/confidence.py:118-121`**, which clamps a
negative age to zero and treats it as current, citing clock skew. The
divergence is deliberate: if H4 clamped, a future-dated observation would make
a dimension look `current` while the condition grammar refused to use it at
all, and the two evaluators would disagree about the same record.

### Not decided here

**Contradicting sources** remain ADR-0013's and H10's; this module does not
detect or arbitrate them, and so never emits the contradiction cause for the
review flag. **`insufficient-policy`** is a health *state* about a missing
condition threshold, decided by the deriving layer, not a freshness outcome.

---

## 6. Module boundary and guard transition

### Where A4 belongs

In a new `tools/health/freshness.py`, by the architecture H3A established: an
evaluator is not a record model, and ENG-0006-D schedules a third evaluator
(A5, hysteresis) after this one. Putting A4 in `records.py` would recreate
exactly the problem H3A was authorised to fix, and putting it in
`conditions.py` would make the ADR-0019 condition grammar also the home of a
rule the standard owns. The module count now matches the component count.

### One shared helper was hoisted, not duplicated

Both evaluators must select observations for one dimension and refuse a
cross-subject set. That is a property of the **records**, not of either
evaluation, so `_observations_of` moved out of `conditions.py` into
`records.py` as **`select_observations(observations, dimension, *, kind)`**,
with `kind` naming the operation to report in a refusal so neither caller
borrows the other's label. Two copies of a subject-binding guard would have
been two things to keep in step, and the copy that drifted would be the one
nobody re-read.

Proof this changed nothing: `tests/test-health-conditions.sh` is **unchanged at
294/0** and `tests/test-health-records.sh` **unchanged at 694/0**.

### The fifth allowlist entry

`tools/health/freshness.py` was added to the four closed allowlists —
`test-capability-health.sh:249-255`, `test-capability-fabric.sh:880`,
`test-static.sh:1461`, `test-docs-static.sh:1178`. **One name per increment, no
rule relaxed**: all four still compare by exact equality, and zero wildcard or
prefix patterns exist in any of them.

The in-suite intruder battery grew from 17 to **23**, the new names chosen to
catch a prefix rule: `freshness_v2.py`, `freshness.pyc`, `xfreshness.py`,
`freshness_store.py`, `freshness_collector.py`, and a directory named
`freshness`.

**Negative proof, in a real `git clone` of the H4 tree:** `store.py`,
`collector.py`, `scheduler.py`, `daemon.py`, `freshness_v2.py`,
`freshness_collector.py`, `xfreshness.py`, `conditions_v2.py`, `evaluator.py`
and a nested `execution/launch.py` are each **rejected by all four guards**,
while the compliant tree passes all four.

**The other controls still bite, tested against the new module:** a
`__main__.py` entry point, an executable bit on `freshness.py`, a banned
`socket` import in `freshness.py`, and a `tools.fabric` import in
`freshness.py` are each rejected. No prohibited-import, entrypoint, clock or
Fabric isolation control was weakened.

---

## 7. RED before GREEN

| run | passing | failing | exit |
|---|---|---|---|
| **RED** — suite written, no freshness module | 9 | **1** | 1 |
| **GREEN** — module implemented | **217** | **0** | 0 |

RED stops after the nine schema-and-standard oracle premises, then the import
of `tools.health.freshness` fails and the suite exits rather than cascading.

**Three of my own test defects were found during GREEN and fixed rather than
accommodated**, each of which would have asserted something false:

1. An assertion expected availability evidence 5000s old to be `current`
   against a 3600s policy. It is `stale`; 5000 > 3600. Replaced with the
   correct pair — stale at 3600s, current at 6000s — which actually
   demonstrates "the same evidence, a different policy".
2. An assertion expected `{"latency": None}` to be **refused** by the envelope
   entry point. A null policy is *permitted* by CHENV and must flow through to
   `unknown` with `review_required`. Corrected to assert that instead.
3. The "does not import the freshness module" checks matched the substring
   `freshness`, which appears legitimately in both other modules as a field and
   parameter name. Rewritten to match import statements only.

---

## 8. Mutation evidence

Fifteen mutations, each applied in a `git archive` sandbox with streams
separated and the module restored byte-for-byte afterwards. **Verdicts read
from exit codes.**

| # | mutation | detected |
|---|---|---|
| 1 | the policy limit becomes exclusive (`>=`) | **yes** — 4 failing |
| 2 | the limit becomes inclusive one second late | **yes** — 4 failing |
| 3 | invent a default aging threshold at half the policy | **yes** — 9 failing |
| 4 | a null policy stops setting `review_required` | **yes** — 2 failing |
| 5 | a null policy becomes a default maximum age | **yes** — uncaught refusal |
| 6 | absent evidence is reported as `stale` | **yes** — 15 failing |
| 7 | a failed collection carries an age | **yes** — 11 failing |
| 8 | a future observation carries an age | **yes** — 11 failing |
| 9 | the **oldest** collected observation is used | **yes** — 5 failing |
| 10 | read the clock instead of the supplied instant | **yes** — 48 failing |
| 11 | read the **stored** freshness label instead of computing | **yes** — 6 failing |
| 12 | the envelope entry point collapses to a worst-dimension scalar | **yes** — 2 failing |
| 13 | a dimension with no evidence is omitted from the envelope result | **yes** — 2 failing |
| 14 | an aging threshold outside the policy is accepted | **yes** — 2 failing |
| 15 | a non-positive policy is accepted | **yes** — 2 failing |

### Two mutations initially survived, and the suite was strengthened

Mutations **9** and **13** were **not detected** on the first pass, and both
were real gaps rather than equivalent mutants:

- **9** survived because no fixture held two *collected* observations of one
  dimension straddling the policy — so oldest-versus-newest never changed a
  verdict. Five assertions were added: newest 5s beside oldest 600s is
  `current` at age 5; the cited `observation_id` is the newest one; when every
  observation is past policy the newest still sets the age; and the newest also
  decides the aging band.
- **13** survived because the only no-evidence envelope fixture passed a
  *non-empty* observation list, so the `if not observations: continue` mutation
  never fired. Four assertions were added for a wholly empty observation set
  across three declared dimensions.

Both mutations are detected after the additions. This is recorded because the
first measurement was wrong and the suite, not the implementation, was at fault.

> **CORRECTION, ENG-0006-H4A.** Three counts in the table above were
> **measured against the pre-addition suite** and were stale: mutation 6 read
> 14, mutation 8 read 7, and mutation 10 read 52. Against the committed suite
> they are **15, 11 and 48**, as now shown. The cause is that thirteen of the
> fifteen rows were measured on the first pass and only mutations 9 and 13
> were re-measured after the nine assertions were added, so the table mixed
> two suite states.
>
> **The measurement history is deliberately preserved rather than erased**:
> mutations 9 and 13 genuinely survived the first pass, which is why those
> assertions exist, and the initial figures for 6, 8 and 10 were genuine
> measurements of a suite that no longer exists. **Every verdict was and
> remains DETECTED**, and all fifteen reproduce from the committed tree —
> twelve counts matched exactly on reproduction and these three did not.

---

## 9. Validation

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-freshness.sh` *(new)* | 0 | **217** | 0 |
| `test-health-conditions.sh` | 0 | 294 | 0 |
| `test-health-records.sh` | 0 | 694 | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | **501** | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-static.sh` | 0 | **875** | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

**AC 25 preserved** — 20 assertions.

**H1 through H3A behaviour is preserved**, and the evidence is that the three
earlier Health suites report exactly their previous totals: records **694**,
binding **87**, conditions **294** — unchanged despite `select_observations`
moving into `records.py` and being called from a second module.

**Assertion-count changes accounted for.** `test-capability-health.sh`
494 → 501 (six new intruders plus the fifth approved module checked present);
`test-static.sh` 874 → 875 (it enumerates shell scripts and there is one more).
Every other suite is unchanged.

**Suite registration.** `tests/test-health-freshness.sh` follows the
per-increment convention and is registered in `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`, with `TOTAL_STEPS` raised in both modes
(146 → 147 quick, 171 → 172 full). `test-developer-experience.sh` asserts every
suite in `tests/` is wired into local validation and still passes.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| at H3A (`7114f63`) | 156 | 128 | 28 |
| **with H4** | **157** | **129** | **28** |

- newly failing: **none**
- no longer failing: **none**
- **identical failing membership: YES**, compared name-by-name

The suite count rises by exactly one — the new H4 suite — and the passing count
by exactly one with it. **The full validator remains red** on the same 28
pre-existing failures, dominated by the generation installer and
helper-ceremony suites carrying the known hard-coded
`REPOSITORY="/opt/schott-platform"` provisioning defect. No baseline failure
was repaired and none was introduced.

---

## 10. Scope and production isolation

**Twelve files — eight modified, four new** (the original count of eleven
omitted this report itself; corrected in ENG-0006-H4A)**:**

| file | change |
|---|---|
| `tools/health/freshness.py` | **new**; the A4 evaluator |
| `tools/health/records.py` | gains `select_observations` (hoisted, §6) |
| `tools/health/conditions.py` | calls the hoisted helper instead of its own copy |
| `tools/health/__init__.py` | re-exports the five new names |
| `tests/test-health-freshness.sh` | **new**; 217 assertions |
| `tests/test-capability-health.sh` | fifth allowlist entry, fixture copy, six intruders |
| `tests/test-capability-fabric.sh` | one `case` alternative |
| `tests/test-static.sh` | one `case` alternative |
| `tests/test-docs-static.sh` | one `case` alternative |
| `tools/dev/run-validation.sh` | registration, `TOTAL_STEPS` +1 in both modes |
| `.github/workflows/ci.yml` | registration |
| this report | **new** |

**Not touched:** `tools/health/errors.py` (byte-identical, **27** codes — no new
refusal code was introduced), every schema, every ADR, the ontology, the Fabric,
the Capability Runtime, Trust, collectors and provisioning.

**Production isolation:**

| check | result |
|---|---|
| `/var/lib/kyri/health` | **absent** |
| `CH*` records under `/var/lib` | **0** |
| Health listener, daemon, collector or heartbeat receiver | **0** |
| Production Fabric, Trust or Capability mutation | **none** |
| Root operations | **none** — no `sudo` invoked |
| Deployment | **none** |

No Health record is produced, consumed, stored or read by anything, and nothing
outside `tools/health` imports the package. The clone-based guard probes and the
mutation runs targeted scratchpad copies, never the working tree.

---

## 11. Open architecture questions

**New here:**

- **Q-H4-1** no aging threshold is declared anywhere for Health; `aging` is
  unreachable until one is. *Recommend declaring it on the CHENV dimension
  entry.*
- **Q-H4-2** the review flag on absent evidence: Health's enumeration excludes
  it, the Knowledge plane's released implementation includes it.
- **Q-H4-3** future-dated observations: H4 excludes them, `confidence.py`
  clamps them to zero.

**Carried forward, unchanged:**

- **Q-H3-1** what `windowed_count` counts; **Q-H3-2** future-dated observations
  in the condition grammar; **Q-H3-3** `measured_value` has no declared
  representation anywhere and H1 does not validate it — **still required before
  H9**; **Q-H3-4** subject agreement enforced in the evaluators.
- **Q-H2A-2** withheld publication authority; **Q-H2A-3** evidence-list
  cardinality; **Q-H2-1** the `EVALUATED_AGAINST` annotation; **Q-H2-2** the
  CHDEG state-citation ambiguity.
- The schema has **no general unknown-key rejection mechanism**.
- **D1–D7** all unresolved. **D5 still blocks heartbeat receiving.** **D6
  remains deferred and actively refused** by the condition grammar.

### What this increment did not do

No hysteresis or continuity evaluator (A5/H5), no state derivation (D1c/H10),
no Health store, no collector, no heartbeat receiver, no Fabric integration, no
new refusal code, no schema change, and no contradiction resolution. H4 did not
interpret `measured_value` and did not impose the still-undeclared boolean
measurement convention: freshness is a property of `observed_at` and the
declared policy, and the measured value is never read.
