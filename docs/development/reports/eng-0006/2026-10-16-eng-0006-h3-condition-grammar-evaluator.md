# ENG-0006-H3 — Condition Grammar Evaluator

**Date:** 2026-10-16
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `f4e6f02427517bec0bb8cf018b3bf9d5b62f49cf`
**Component:** A3 from the committed ENG-0006-D plan, and only A3.
**Status:** READY FOR REVIEW

---

## 1. Normative sources

Every behaviour below traces to one of these. Nothing was decided here.

| Source | What it fixes |
|---|---|
| `ADR-0019-health-condition-grammar.md:58-72` | the five operators, closed; no `ne`, ranges, combinators or negation |
| `ADR-0019:74-78` | a decimal string, compared as an exact decimal, never a binary float |
| `ADR-0019:80-100` | one declared unit per dimension; a mismatch is refused, never converted |
| `ADR-0019:102-121` | `instant` and `windowed_count`, closed at two; half-open window anchored at the evaluation instant |
| `ADR-0019:123-141` | percentiles excluded from this release |
| `ADR-0019:233-236` | ordering by `observed_at` ascending, ties by identifier ascending |
| `ADR-0019:238-243` | no rounding rule exists, by construction |
| `ADR-0019:245-250` | contradictions are **not** resolved by the grammar |
| `capability-health-envelope.schema.yaml:146-164` | `condition_operators`, `condition_value_representation: decimal-string`, `aggregations`, `percentile_aggregation: forbidden` |
| `capability-health-envelope.schema.yaml:168-181` | `window_boundaries: start-inclusive-end-exclusive`, `windowed_count_fields.required`, `unit_mismatch: refuse`, `unit_conversion: forbidden` |
| `capability-health-envelope.schema.yaml:124-126` | `freshness_policy_seconds` — "Null is permitted… It must never be defaulted to a number" |
| `capability-health-observation.schema.yaml:54-56`, `:110-113` | `measured_value` null unless `collected`; the three collection statuses |
| ENG-0006-D `:152-161` | component A3's purpose, in/out, failure modes and required tests |
| ENG-0006-D `:559` | H3's required negative tests |

---

## 2. The grammar as implemented

One keyword-only entry point, `evaluate_condition`, returning a frozen
`ConditionResult`.

```python
evaluate_condition(*, dimension, unit, condition, aggregation,
                   freshness_policy_seconds, observations, evaluated_at)
    -> ConditionResult(outcome, aggregation, observation_ids, count,
                       unknown_reason)
```

**Outcomes are `satisfied`, `not-satisfied`, `unknown` — never a health
state.** `satisfied` means the declared condition held at the evaluation
instant. Turning that into `degraded` requires hysteresis (A5/H5) and
worst-dimension-wins combination (H10). Conflating them here would let one slow
response degrade a subject, which is the exact thing ADR-0013 requires
hysteresis to prevent, so the vocabulary is kept disjoint and a test asserts an
outcome is never a state name.

**Operators.** `gt ge lt le eq`, read from the schema by the suite. Anything
else — `ne`, `!=`, `>`, `between`, `and`, a case variant, a non-string — is
refused with `operator-not-permitted`.

**Exact decimals.** Both sides of every comparison go through H1C's
`_decimal_text`, so a `float` is refused outright and `NaN`, `sNaN` and
`Infinity` are refused as non-finite. Comparison is `Decimal`, so `eq` is
numeric rather than textual: `"1"` equals `"1.0"` equals `"1.00"`, and `"2000"`
equals `"2.0e3"`, because those are the same exact decimal.

**`instant`.** The single **newest** usable observation of that dimension. Not
the worst, and not an average — averaging would need a rounding rule nobody
declared. With no usable observation the outcome is `unknown`.

**`windowed_count`.** `window_seconds` and `min_samples` are both required and
neither may be defaulted. The window is
`[evaluated_at − window_seconds, evaluated_at)` — start-inclusive,
end-exclusive. Fewer usable observations than `min_samples` yields `unknown`.

**Usability.** `collection_status: collected`, a measurement present, and an
age within `freshness_policy_seconds`.

**A null freshness policy yields `unknown`.** The schema permits null and
forbids defaulting it to a number; treating null as "no age bound" would
default it to infinity, which is the favourable default the Null Policy Rule
exists to prevent. The `review_required` flag that must accompany it belongs to
A4/H4 and is not claimed here.

---

## 3. Explicitly unsupported, and refused

| Refused | Code | Why |
|---|---|---|
| Any operator outside the five | `operator-not-permitted` | closed set |
| `p95`, `p99`, `percentile`, `mean`, `median`, `sum`, `max`, `min`, `stddev`, `rate` | `aggregation-not-permitted` | `percentile_aggregation: forbidden`; D6 stays deferred |
| A percentile *with* a declared interpolation | `aggregation-not-permitted` | still not expressible against one-measurement-at-one-moment records |
| An expression string as a condition (`"p95 > 2000ms"`, `"> 32"`) | `field-type-invalid` | `condition_expression_strings: forbidden`; there is no parser |
| An envelope `unit` that is not the dimension's declared unit | `unit-mismatch` | `unit_mismatch: refuse`, `unit_conversion: forbidden` |
| An undeclared dimension | `dimension-not-declared` | closed set of thirteen |
| `windowed_count` without `window_seconds` or `min_samples` | `missing-required-field` | a defaulted continuity parameter is an unanswered question dressed as an assessment |
| A non-decimal or non-finite threshold or measured value | `field-type-invalid` | exact-decimal comparison |
| A `float` threshold | `field-type-invalid` | representation-dependent, so not deterministic |
| An unknown member on a condition or aggregation | `unknown-field` | fail closed |
| A naive or non-string evaluation instant | `timestamp-not-offset-aware` / `field-type-invalid` | the same rule H1 applies to every instant |
| A freshness policy of `0`, negative, a string, a float or a bool | `field-type-invalid` | whole seconds ≥ 1, or null |
| Observations that are not parsed records, or of another family | `field-type-invalid` / `cited-record-kind-mismatch` | the record model is the gate |
| Observations of two different subjects | `cross-subject-citation` | see §7 |

**No new refusal code was introduced.** `tools/health/errors.py` is
byte-identical and the vocabulary stays at **27** codes.

**No new module.** The evaluator lives in `tools/health/records.py` — see §8.

---

## 4. What the evaluator cannot do

Asserted, not asserted-in-prose:

| Constraint | How it is enforced |
|---|---|
| Never reads the system clock | `evaluated_at` is keyword-only with **no default**, so an implicit "now" cannot be introduced at a call site; the suite also greps the module for `datetime.now`, `utcnow`, `time.time`, `time.monotonic`, `date.today`, `utcfromtimestamp` |
| No I/O | no `socket`, `subprocess`, `requests`, `urllib`, `http`, `asyncio`, `threading`, `multiprocessing` or `sqlite3` import; asserted by name |
| No dynamic execution | no `eval`, `exec`, `compile` or `__import__` call, matched at a call boundary |
| Writes no Health record | returns a `ConditionResult`; no store, no path, no write |
| Starts no collector or heartbeat receiver | no such entry point exists; asserted absent by name |
| Determines no Fabric eligibility | asserted absent by name |
| Modifies no Trust | asserted absent by name |
| Executes no recommendation | asserted absent by name |
| Imports no Fabric runtime module | AC 25's existing battery still passes, including "no fabric module imports the health package" |
| Mutates nothing | the supplied condition, aggregation, sequence and every observation are byte-identical after evaluation; the result itself refuses assignment |

---

## 5. RED before GREEN

The suite was written first, against the committed schema as its oracle, and
run before any evaluator existed.

| run | passing | failing | exit |
|---|---|---|---|
| **RED** — suite written, no evaluator | 8 | **2** | 1 |
| **GREEN** — evaluator implemented | **280** | **0** | 0 |

RED stops after 8 assertions by design: the eight schema-oracle premises pass,
then `evaluate_condition` and `CONDITION_OUTCOMES` are found absent and the
suite exits rather than reporting 270 cascading failures against a function
that does not exist. This is the D plan's requirement that the suite "must be
written first and shown failing against an empty implementation" (`:441`).

Three of my own harness bugs were found and fixed during GREEN rather than
accommodated, and they are recorded because each would have produced a test
that could not fail:

1. `run()` substituted its default whenever `None` was passed, so
   `evaluated_at=None` silently became a valid instant. Replaced with an
   explicit `_UNSET` sentinel.
2. `list(42)` raised `TypeError` in the harness before the evaluator saw it, so
   the non-sequence case was never actually tested. Now calls the evaluator
   directly, across five non-sequence types.
3. The banned-call check used a bare substring, and `re.compile(` contains
   `compile(`. Now matched at a call boundary.

A fourth was a worthless leakage guard: `forbidden_value=""` is a substring of
every message, so it is now applied only to values with non-blank content.

---

## 6. Mutation evidence

Fourteen mutations, each applied to the corrected implementation in a
`git archive` sandbox, the suite run with streams separated, and the module
restored byte-for-byte afterwards. **Verdicts are read from the exit code**, not
from counting `FAIL` lines — one mutation is caught by an uncaught refusal that
prints a traceback rather than a `FAIL`.

| # | mutation | detected | exit | signal |
|---|---|---|---|---|
| 1 | compare as binary floats instead of exact decimals | **yes** | 1 | 3 failing |
| 2 | admit a percentile aggregation | **yes** | 1 | 3 failing |
| 3 | admit an extra operator (`ne`) | **yes** | 1 | 1 failing |
| 4 | drop the required-member check on an aggregation | **yes** | 1 | 3 failing |
| 5 | a thin window becomes a verdict instead of `unknown` | **yes** | 1 | 5 failing |
| 6 | a null freshness policy becomes "no age bound" | **yes** | 1 | 1 failing |
| 7 | an unusable observation produces a verdict | **yes** | 1 | uncaught refusal |
| 8 | ignore the freshness age bound entirely | **yes** | 1 | 4 failing |
| 9 | window becomes end-inclusive | **yes** | 1 | 1 failing |
| 9b | window becomes start-exclusive | **yes** | 1 | 1 failing |
| 10 | `instant` picks the oldest usable observation | **yes** | 1 | 4 failing |
| 11 | read the clock instead of the supplied instant | **yes** | 1 | 58 failing |
| 12 | evaluate across subjects instead of refusing | **yes** | 1 | 2 failing |
| 13 | accept an expression string as a condition | **yes** | 1 | 6 failing |
| 14 | the outcome becomes a health state (`degraded`/`healthy`) | **yes** | 1 | 31 failing |

Mutation 7 is worth naming: making a failed collection "usable" does not
produce a wrong verdict, it produces a **refusal**, because a failed collection
has no `measured_value` and the decimal check rejects `None`. The usability
filter and the exact-decimal requirement reinforce each other.

### A mutation that found dead code, and the code was removed

An earlier draft also compared each observation's `unit` against the envelope's
inside the observation filter. Deleting that comparison was **undetectable** —
no fixture could construct the case. The reason is that ADR-0019's requirement
holds *transitively*: `evaluate_condition` refuses an envelope `unit` that is
not the dimension's declared unit, and the record model already refuses an
observation whose `unit` is not that same declared unit, so both sides are
pinned to one value and cannot differ. The branch was unreachable, so it was
**removed** rather than kept as an untestable guard, and the reasoning is
recorded in the function's docstring. The requirement is still enforced, and a
mismatch is still refused — at the envelope check, which mutation evidence
does cover.

---

## 7. Interpretations taken, and recorded for the reviewer

Each of these is a point where the normative text admits one supportable
reading rather than stating the rule outright. None was decided on
convenience, and each is flagged so the reviewer can overrule it.

### Q-H3-1 — what `windowed_count` counts

ADR-0019:114 says "The comparison applies to the **count of qualifying
observations** in the window", and the next sentence says "a window holding
fewer **usable** observations yields `unknown`". "Qualifying" is defined
nowhere else; "usable" is defined precisely (`:180-182`). Taken as
**qualifying = usable**, on the parallel structure of those two sentences. The
alternative — a second, unstated predicate — would require inventing the
predicate, which the ADR never states. Under this reading `measured_value` is
not consulted for `windowed_count`, which is consistent with the ADR's framing
of those two dimensions as "outcomes over a declared window".

### Q-H3-2 — observations dated after the evaluation instant

No rule is declared for `instant`. Evidence recorded after the moment an
assessment was made cannot support that assessment, so such observations are
excluded, reusing the end-exclusive convention the grammar already declares for
windows rather than inventing a second rule. An observation exactly *at* the
evaluation instant remains usable for `instant` and is excluded from a window,
which is what `start-inclusive-end-exclusive` says.

### Q-H3-3 — `measured_value` has no declared representation (and H1 does not validate it)

**Nothing anywhere declares what a `measured_value` is.** CHENV declares
`condition_value_representation: decimal-string` for the *threshold*; CHOBS
declares nothing for the *measurement*, and `docs/health/observation-model.md`
says only that a failed collection has none.

Consequently **H1 does not type-validate it at all** — verified: a `collected`
observation carrying `"banana"`, `True`, `1500`, `[1]`, `{"a": 1}`, `"NaN"` or
`"Infinity"` is accepted by `parse()` today. This is a pre-existing H1
conformance gap, **not** introduced here and **not** fixed here, because
`measured_value`'s representation is a schema question and this increment is
authorised for A3 only.

H3 refuses a non-decimal or non-finite measured value **at evaluation time**,
because ADR-0019 requires the comparison to be an exact decimal one and that is
unsatisfiable otherwise. A consequence worth the reviewer's attention: the
`boolean`-unit dimensions (`availability`, `transport-health`) therefore have
to be written as `"1"` and `"0"`, since `"true"` is not a decimal — and nothing
declares that either.

*RECOMMENDATION:* declare `measured_value`'s representation on CHOBS and add
the matching H1 refusal, as a small increment of its own.

### Q-H3-4 — subject agreement is enforced here

The evaluator refuses an observation set naming more than one subject, with
`cross-subject-citation`. A3's spec does not list this, so it is an addition:
the justification is ADR-0013:553-563, which requires every cited observation
to share the state's subject, and ADR-0013:185-189's warning that a verdict
assembled from another subject's measurements is "well-formed, correctly typed,
and false". Fail-closed and three lines. Flagged in case the reviewer prefers
it left to H2's citation validation and H10's derivation.

### Not decided here, by design

**Contradicting sources.** ADR-0019:245-250 states that the grammar "receives
that result and must not resolve contradictions itself". The evaluator
therefore does **not** detect or arbitrate contradicting fresh observations;
it applies the declared `instant` rule — newest wins, with ties broken by
identifier — and returns the observation it used so the caller can do its own
contradiction handling. That remains ADR-0013's and H10's.

---

## 8. Module placement — a constraint, not a design choice

The evaluator is in `tools/health/records.py`, which is **not** where an
evaluator belongs.

H1B established a **closed allowlist** of exactly three files under
`tools/health` — `__init__.py`, `records.py`, `errors.py` — enforced
independently by **four** suites (`test-capability-health.sh:240-244`,
`test-capability-fabric.sh:880`, `test-static.sh:1461`,
`test-docs-static.sh`). Creating `tools/health/conditions.py` would fail all
four, and §7 of the standing rules forbids weakening a guard to obtain a pass.
H2 hit the same constraint and resolved it the same way.

The difference is worth stating plainly: H2 could argue the placement was
*honest*, because subject binding is a property of records. **Here it is
merely convenient.** Condition evaluation is not a property of a record, and
`records.py` is now 1,221 lines holding a record model and an evaluator.

*RECOMMENDATION:* authorise a small guard-transition increment — the H1B
pattern — that admits `tools/health/conditions.py` to the four allowlists and
moves this code there, **before** H4 and H5 add a freshness evaluator and a
hysteresis evaluator to the same file. Three evaluators in `records.py` is a
structure nobody would choose.

---

## 9. Validation

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-conditions.sh` *(new)* | 0 | **280** | 0 |
| `test-health-records.sh` | 0 | 694 | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | 487 | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-static.sh` | 0 | **874** | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

**AC 25 preserved** — 20 AC 25 assertions pass, including "no fabric module
imports the health package", "the health package was never imported while the
operations ran", and "no CLI option or subcommand can supply a health input".

**Assertion-count changes accounted for.** `test-static.sh` moved 873 → 874: it
enumerates the repository's shell scripts, and the new suite is one more. Every
other suite reports exactly the totals it did before this increment.
`test-health-records.sh` is unchanged at 694, which is the evidence that
H1/H2/H2A/H2B behaviour is preserved.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| established baseline | 155 | 127 | 28 |
| **with H3** | **156** | **128** | **28** |

- newly failing: **none**
- no longer failing: **none**
- **identical failing membership: YES**, compared name-by-name against the
  recorded 28-suite list rather than by total

The suite count rises by exactly one — the new H3 suite — and the passing count
by exactly one with it. **The full validator remains red** on the same 28
pre-existing failures, dominated by the generation installer and
helper-ceremony suites carrying the known hard-coded
`REPOSITORY="/opt/schott-platform"` provisioning defect. No baseline failure was
repaired and none was introduced.

**Suite registration.** H3 follows the established per-increment convention
(H1 → `test-health-records.sh`, H2 → `test-health-binding.sh`):
`tests/test-health-conditions.sh` is registered in `tools/dev/run-validation.sh`
and `.github/workflows/ci.yml`, and `TOTAL_STEPS` is raised in both modes
(145 → 146 quick, 170 → 171 full). `test-developer-experience.sh` asserts every
suite in `tests/` is wired into local validation and still passes, which is what
proves the registration is real rather than cosmetic.

---

## 10. Production isolation

| check | result |
|---|---|
| `/var/lib/kyri/health` | **absent** |
| `/var/lib/kyri` contents | **empty** |
| `CH*` records under `/var/lib` | **0** |
| Health listener or daemon | **0** |
| Production Fabric, Trust or Capability mutation | **none** |
| Root operations | **none** — no `sudo` invoked |
| Deployment | **none** |

Nothing outside `tools/health` imports the package. No Health record is
produced, consumed, stored or read by anything. The mutation runs targeted a
scratchpad sandbox, never the working tree.

---

## 11. Carried forward, unresolved

- **Q-H2A-2** withheld publication authority.
- **Q-H2A-3** evidence-list cardinality for `unknown` / `withheld`.
- **Q-H2-1** the `EVALUATED_AGAINST` ontology annotation.
- **Q-H2-2** the CHDEG state-citation ambiguity.
- **D1–D7** all unresolved. **D5 still blocks heartbeat receiving.** **D6
  (percentile aggregation) remains deferred and is actively refused**, which is
  the behaviour D assigned to H3.
- The schema has **no general unknown-key rejection mechanism**.
- **New here:** Q-H3-1 through Q-H3-4 (§7) and the module-placement
  recommendation (§8).

Nothing in A4 (freshness), A5 (hysteresis and continuity) or D1c (state
derivation) was implemented. No percentile support was added.
