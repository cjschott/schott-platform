# ENG-0006-H5 — Hysteresis and Continuity Evaluator

**Date:** 2026-10-20
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `8447e8c33f93b1a1b620629f65d5d96104eec7d8` (H4B, published)
**Component:** A5 from the committed ENG-0006-D plan, and only A5.
**Status:** READY FOR REVIEW

---

## 1. Committed authority

| Source | What it fixes |
|---|---|
| `ADR-0019:176-190` | the four conjunctive clauses over a candidate interval `[t0, t1]`: duration, violation throughout, minimum coverage, maximum gap |
| `ADR-0019:181-183` | a usable observation is `collection_status: collected`, with a `measured_value`, and an age within `freshness_policy_seconds` |
| `ADR-0019:186-190` | the maximum gap applies to consecutive observations **and** to both interval boundaries — "without them an interval could be padded at either end by time nothing was measured" |
| `ADR-0019:192-200` | the three reset conditions |
| `ADR-0019:202-209` | "A gap resets the interval regardless of why it exists" — `collection_failure_implies_subject_failure: false` enforced arithmetically, so "a monitoring failure therefore cannot produce a transition" |
| `ADR-0019:210-212` | exit uses `exit_condition` under the same four rules |
| `ADR-0019:148-168` | `duration` is the only kind in v1; `occurrences` is not supported |
| `capability-health-envelope.schema.yaml:200-212` | `hysteresis_kinds: [duration]`; all four members required, none defaulted |
| `capability-health-envelope.schema.yaml:220-228` | `hysteresis_continuity`, including `gap_applies_to_interval_boundaries: true`, both reset flags, and `gap_cause_affects_reset: false` |
| `capability-degradation-event.schema.yaml:61-73` | the six required hysteresis proof fields plus `derived_from_observation_ids` |
| `capability-degradation-event.schema.yaml:87-88` | `hysteresis_continuity: declared-required`, `unprovable_transition: refuse` |
| ENG-0006-D `:172-180` | component A5's purpose, in/out, upstream (**A1, A3, A4**), failure modes and required tests |
| ENG-0006-D `:561` | H5's required negative tests |

---

## 2. The evaluator contract

One keyword-only entry point in the new `tools/health/hysteresis.py`:

```python
evaluate_hysteresis(*, dimension, unit, condition, hysteresis,
                    freshness_policy_seconds, observations,
                    evaluated_at) -> HysteresisResult
```

`HysteresisResult` is frozen and carries `outcome`, `reason` and `proof`.
`HysteresisProof` is frozen and carries exactly the seven CHDEG names — no
field name is invented here.

| outcome | meaning |
|---|---|
| **`satisfied`** | all four clauses met **and** every CHDEG proof element established. Carries a proof. |
| **`unsatisfied`** | a candidate interval exists and fails a declared requirement. Carries **no** proof. |
| **`unprovable`** | no candidate interval exists, so there is nothing to judge. Carries no proof. |

`reason` comes from a closed vocabulary: `duration-not-met`,
`coverage-below-minimum-samples`, `gap-exceeds-maximum` for `unsatisfied`, and
`no-candidate-interval`, `null-freshness-policy`, `proof-incomplete` for
`unprovable`.

**The three outcome labels are internal result values, not schema values.**
Asserted: none appears in CHDEG's `from_state` enum. H5 introduces no new
public schema vocabulary.

### Violation is decided by the condition evaluator, not re-implemented

ENG-0006-D lists **A3 among A5's upstream components**, so each observation is
classified by calling the **public** `evaluate_condition` with that single
observation under `instant` aggregation:

| condition outcome | classification |
|---|---|
| `satisfied` | usable **and** violating |
| `not-satisfied` | usable and not violating |
| `unknown` | not usable |

One audited comparison. The exact-decimal semantics, the usability rule and the
future-observation exclusion are all inherited rather than duplicated, and no
private name is imported across a module boundary.

---

## 3. Continuity semantics

`t1` is the caller's evaluation instant. `t0` is the first observation of the
**latest unbroken run** of violating usable observations, found by walking back
from the newest usable observation and stopping at a non-violating one or at a
gap exceeding the maximum. Walking backwards computes the reset rules directly:
a gap in *usable* observations is exactly what a collection outage produces, and
its cause never enters the arithmetic.

| boundary | behaviour | authority |
|---|---|---|
| achieved duration **exactly** `seconds` | satisfied | `t1 − t0 ≥ seconds` |
| one second short | `unsatisfied` / `duration-not-met` | same |
| gap **exactly** `max_gap_seconds` | does **not** reset | the rule resets on a gap *exceeding* the maximum |
| gap one second over | resets | same |
| last-to-`t1` gap exactly at the maximum | permitted | `gap_applies_to_interval_boundaries: true` |
| last-to-`t1` gap over the maximum | `unsatisfied` / `gap-exceeds-maximum` | the monitoring-outage rule |
| usable count exactly `min_samples` | satisfied | "at least `min_samples`" |
| one below | `unsatisfied` / `coverage-below-minimum-samples` | same |

**Collection failure.** A failed or unavailable collection is never a
violation and never carries the interval: it is classified `unknown` by the
condition evaluator and excluded. A wall of failed collections is
**`unprovable`**, never satisfied. An outage mid-interval resets continuity,
and the report asserts the *exact* reason — `duration-not-met`, the surviving
run being too short — rather than accepting any failure, because the raw span
across the outage would otherwise have passed for the same verdict by a
different route.

**Non-violating reset.** A non-violating usable observation resets the
interval. The suite isolates this from the gap rule with a maximum gap wide
enough to span the non-violating observation, so the gap rule cannot cover for
a deleted violation reset.

**Future observations** are excluded, inherited from the condition evaluator,
and a future observation is never cited in a proof.

**A null freshness policy** yields `unprovable` / `null-freshness-policy`.
Defaulting it would convert an unanswered configuration question into a
confident-looking assessment — the Null Policy Rule, unchanged from H4.

---

## 4. The transition proof

Produced **only** when the outcome is `satisfied`, and carrying exactly the
CHDEG names:

| field | content |
|---|---|
| `hysteresis` | the resolved declaration, quoted, so the event stays readable after the envelope is superseded |
| `hysteresis_satisfied_over_seconds` | `t1 − t0`, the achieved duration |
| `hysteresis_first_observation_id` | the interval's start |
| `hysteresis_last_observation_id` | the interval's end |
| `hysteresis_sample_count` | the usable observations in the interval |
| `hysteresis_observed_max_gap_seconds` | the largest gap, **including the last-to-`t1` boundary gap**, because clause 4 tests that gap against the same declared maximum |
| `derived_from_observation_ids` | the ordered interval, so the whole judgement is re-checkable |

Asserted: the cited evidence count equals the sample count, and the evidence
runs from the first to the last observation identifier. A dedicated fixture
pins the boundary-gap inclusion — a 25-second trailing gap under a 30-second
maximum reports **25**, not the 10-second inter-observation gap.

**`unprovable_transition: refuse` is enforced:** before claiming `satisfied`,
every proof element is checked to be established, and a missing one returns
`unprovable` / `proof-incomplete`.

**H5 writes nothing.** No CHDEG record and no CHSTATE record is created,
derived or stored. The result is a verdict and a proof object, and the
increment asserts the absence of `write_record`, `write_degradation_event`,
`derive_state`, `emit`, `store` and seven more by name.

---

## 5. RED before GREEN

| run | passing | failing | exit |
|---|---|---|---|
| **RED** — suite written, no hysteresis module | 11 | **1** | 1 |
| **GREEN** — module implemented | **206** | **0** | 0 |

RED stops after the eleven schema-oracle premises, then the import of
`tools.health.hysteresis` fails and the suite exits rather than cascading.

**Two of my own weak assertions were found and strengthened before GREEN was
accepted**, because each was trivially true as written: a future-observation
check compared against a prefix no fixture produces, and a first-observation
check ended in `or True`. Both now assert the real property.

**One editing error is recorded rather than hidden:** inserting a new fixture
block mid-section clobbered the `result` variable two existing assertions
depended on, and they failed. The block was relocated after them rather than
the assertions being adjusted.

---

## 6. Mutation evidence

Seventeen mutations in a `git archive` sandbox, streams separated, module
restored byte-for-byte afterwards, verdicts by exit code.

**Five survived the first pass**, and **four were real test gaps** — the
suite, not the implementation, was at fault:

| # | mutation | first pass | after | why it survived |
|---|---|---|---|---|
| 5 | gap reset removed from the walk | **survived** | **detected** | the final observed-gap check reached the same *outcome* by another route; only the exact *reason* distinguishes them |
| 7 | boundary-gap check removed | **survived** | **detected** | masked until a fixture made the boundary gap and the duration fail together, where the reported cause differs |
| 8 | a non-violating observation no longer resets | **survived** | **detected** | the gap rule was covering for it; isolated with a maximum gap wide enough to span the non-violating observation |
| 17 | observed max gap ignores the boundary | **survived** | **detected** | no fixture had a trailing gap larger than its inter-observation gaps |
| 10 | the proof-completeness guard removed | **survived** | **survives** | see below |

**The other thirteen, all detected:** duration exclusive (1), duration check
removed (2), `min_samples` removed (3) and off by one (4), gap boundary
exclusive (6), unusable observations treated as violating (9), the proof
dropping its sample count (11) or its evidence (12), `occurrences` admitted
(13), a defaulted null policy (14), a clock read (15), `no-candidate-interval`
returning `satisfied` (16).

### Mutation 10 is an equivalent mutant, and is reported as one

Removing the proof-completeness guard changes nothing, because every proof
element is established by construction once the four clauses pass — the guard
is **unreachable in correct operation**. Mutations 11 and 12, which actually
break a proof element, **are** detected, by the suite's own proof assertions
rather than by the guard.

The guard is nonetheless **kept**, which is a different judgement from
ENG-0006-H3, where an unreachable branch was *removed*. The difference: there,
nothing required the branch and no fixture could construct its case; here
CHDEG's `unprovable_transition: refuse` and this increment's brief both require
that a result must not claim a recordable transition unless every required
proof element can be established. It is defence in depth against a future
weakening of the proof builder, and its unreachability is stated rather than
implied.

---

## 7. Module boundary and the H4B guard

`tools/health/hysteresis.py` is new, by the architecture H3A established: an
evaluator is not a record model, and the module count now matches the component
count. It imports `errors`, `records` (for `DIMENSION_UNITS`,
`HYSTERESIS_KINDS`, `_instant`, `_whole`, `select_observations`) and
`conditions` (for the public `evaluate_condition`) — and **not** `freshness`,
which A5 does not need. The dependency still runs one way: no module imports
`hysteresis`.

**The H4B import boundary is preserved and was exercised live.** Before the
allowlist was updated, `test-capability-health.sh` **failed** with
`hysteresis.py` present — real evidence the closed allowlist rejects a
genuinely new module rather than only synthetic fixtures. The sixth name was
then added to the four closed allowlists; all four still compare by exact
equality and no rule was relaxed. The intruder battery grew to **27** with
`hysteresis_v2.py`, `hysteresis.pyc`, `xhysteresis.py`, `hysteresis_store.py`
and a directory named `hysteresis`.

H4B's checks pass against the new module: `the import boundary scans
tools/health/hysteresis.py`, `no health module reaches another plane or a
dynamic-import facility`, and `no cross-plane import is permitted`. Measured
directly: **0** forbidden identifiers and **0** cross-plane imports in
`hysteresis.py`.

### Architectural boundaries asserted

Caller-supplied time (`evaluated_at` keyword-only, no default); deterministic
(24 input orderings and 25 repeats give one identical result); exact-decimal
comparison inherited from A3; subject and dimension isolation (a mixed-subject
set is refused, another dimension is filtered not treated as a gap); no
filesystem I/O, no network, no dynamic import, no cross-plane import; inputs
unmutated; no Fabric authority; no automatic execution.

---

## 8. Deferred and unresolved

### New, recorded here

**Q-H5-1 — where the `unsatisfied` / `unprovable` line falls.** ADR-0019 does
not draw it. Clause 3 makes coverage below `min_samples` a failure of the
clause, which reads as `unsatisfied`; the brief describes `unprovable` as
"available evidence cannot establish the requested transition", which reads
more broadly. H5 takes the narrower, more informative reading: `unprovable`
when **no candidate interval exists at all** (no violating usable observation
reaches the end of the interval, or the policy is null), and `unsatisfied` when
an interval exists and fails a declared requirement. *This distinction is an
interpretation and is flagged for the reviewer rather than presented as
settled.*

**Q-H5-2 — one leg of clause 4 is vacuous as implemented.** Clause 4 requires
"the first is within `max_gap_seconds` of `t0`". Because the reset rule sets
`t0` to a violating usable observation, `t0` **is** the first observation of
the interval, so that distance is always zero and the leg can never fail. The
other leg (last to `t1`) is load-bearing and is enforced. Either `t0` is meant
to be something other than an observation instant — in which case ADR-0019 does
not say what — or the leg is genuinely redundant. Recorded, not resolved.

### Carried forward, untouched

- **Q-H4-1** no aging threshold is declared anywhere for Health; **Q-H4-2**;
  **Q-H4-3**.
- **Q-H3-1** what `windowed_count` counts; **Q-H3-2**; **Q-H3-3**
  `measured_value` has no declared representation anywhere and H1 does not
  validate it — **still required before H9**; **Q-H3-4**.
- **Q-H2A-2**, **Q-H2A-3**, **Q-H2-1**, **Q-H2-2**.
- The schemas have **no general unknown-key rejection mechanism**.
- **D1–D7** all unresolved. **D5 still blocks heartbeat receiving.** **D6
  remains deferred and actively refused.**
- The **H4B fixture-count erratum** (31/25 should read 32/26) and the
  **`__loader__` limitation** remain separate editorial follow-ups and were
  deliberately not touched here.

### What this increment did not do

No health-state derivation (D1c/H10), no degradation-event writing (D2c/H11),
no Health store, no collector, no heartbeat receiver, no Fabric or Trust
change, no background execution, no new runtime authority, no new refusal code,
and no schema change. `exit_condition` evaluation is supported by passing the
exit condition as `condition` — ADR-0019 applies "the same four rules" — and no
separate exit path was invented.

---

## 9. Validation

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-records.sh` | 0 | 694 | 0 |
| `test-health-conditions.sh` | 0 | 294 | 0 |
| `test-health-freshness.sh` | 0 | 217 | 0 |
| `test-health-hysteresis.sh` *(new)* | 0 | **206** | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | **530** | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-static.sh` | 0 | **876** | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

**AC 25 preserved** — 20 assertions.

**H1 through H4B behaviour is preserved**, and the evidence is that
`records.py`, `conditions.py`, `freshness.py` and `errors.py` are
**byte-identical** to H4B, and their suites report exactly their previous
totals: 694, 294, 217 and 87.

**Assertion-count changes accounted for.** `test-capability-health.sh`
523 → 530 (+7: five new intruders plus the sixth approved module checked present
and scanned); `test-static.sh` 875 → 876 (it enumerates shell scripts and there
is one more). Every other suite is unchanged.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| at H4B (`8447e8c`) | 157 | 129 | 28 |
| **with H5** | **158** | **130** | **28** |

- newly failing: **none**; no longer failing: **none**
- **identical failing membership: YES**, compared name-by-name

The suite count rises by exactly one — the new H5 suite — and the passing count
by one with it. **The full validator remains red** on the same 28 pre-existing
failures, dominated by the generation installer and helper-ceremony suites
carrying the known hard-coded `REPOSITORY="/opt/schott-platform"` provisioning
defect. No baseline failure was repaired and none was introduced.

**Suite registration.** `tests/test-health-hysteresis.sh` follows the
per-increment convention and is registered in `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`, with `TOTAL_STEPS` raised in both modes
(147 → 148 quick, 172 → 173 full). `test-developer-experience.sh` asserts every
suite in `tests/` is wired into local validation and still passes.

---

## 10. Scope and production isolation

**Nine files — seven modified, two new:**

| file | change |
|---|---|
| `tools/health/hysteresis.py` | **new**; the A5 evaluator |
| `tools/health/__init__.py` | re-exports the six new names |
| `tests/test-health-hysteresis.sh` | **new**; 206 assertions |
| `tests/test-capability-health.sh` | sixth allowlist entry, fixture copy, five intruders |
| `tests/test-capability-fabric.sh` | one `case` alternative |
| `tests/test-static.sh` | one `case` alternative |
| `tests/test-docs-static.sh` | one `case` alternative |
| `tools/dev/run-validation.sh` | registration, `TOTAL_STEPS` +1 in both modes |
| `.github/workflows/ci.yml` | registration |
| this report | **new** |

**Not touched:** `tools/health/records.py`, `conditions.py`, `freshness.py` and
`errors.py` — all **byte-identical**, and `errors.py` still **27** codes, so no
new refusal code was introduced. No schema, ADR, ontology, Fabric, Capability
Runtime, Trust, collector or provisioning change.

**Production isolation:**

| check | result |
|---|---|
| `/var/lib/kyri/health` | **absent** |
| `CH*` records under `/var/lib` | **0** |
| Health listener, daemon, collector or heartbeat receiver | **0** |
| Production Fabric, Trust or Capability mutation | **none** |
| Root operations | **none** |
| Deployment | **none** |

No Health record is produced, consumed, stored or read by anything, and nothing
outside `tools/health` imports the package. The mutation runs targeted a
scratchpad sandbox, never the working tree.
