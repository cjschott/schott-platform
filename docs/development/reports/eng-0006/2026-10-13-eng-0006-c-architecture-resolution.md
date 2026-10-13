# ENG-0006-C — Approved architecture reconciliation

**Date:** 2026-10-13 · **Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `5a4f55984ae5299530382d29ede48ef3e10473ea` (ENG-0006-B, reviewed)
**Reference:** [ENG-0006-B resolution package](2026-10-13-eng-0006-b-architecture-resolution-package.md)

**RESULT: REVIEW_REQUIRED.** The approved decisions are implemented as normative
corrections to ADRs, Health documentation, schemas, ontology and cross-artefact
tests. **No Health Runtime code, no Health store, no production mutation.**

**The headline evidence.** A new cross-artefact agreement suite was written
**before** any normative change and failed **55 of 87 assertions**. After the
approved corrections it passes **88 of 88**. Those 55 failures are the
specification inconsistencies this increment closed, and they were all invisible
to the existing 461-assertion Health suite — which was green throughout, because
every one of its assertions reads a single artefact.

---

## 1. Disposition, decision by decision

| Finding | Ruling | Disposition |
|---|---|---|
| **C1** state set | accepted as recommended | **IMPLEMENTED** — seven states, five sources agree |
| **C2** recommendation vocabulary | accepted as recommended | **IMPLEMENTED** — four closed kinds, `drain` permitted nowhere |
| **C3** `withheld` semantics | accepted as recommended | **IMPLEMENTED** — ADR table row corrected |
| **G1** selection disclosure | **reconciliation required** | **IMPLEMENTED as amended** — closed pre-disclosure identity set, §2.1 |
| **G2** evidence relationships | accepted as recommended | **IMPLEMENTED** — two dedicated edges, `DERIVED_FROM` untouched |
| **G3** condition grammar | accepted as recommended | **IMPLEMENTED** — ADR-0019 |
| **G4** hysteresis | **reconciliation required** | **IMPLEMENTED as amended** — continuity semantics defined, §2.2 |
| **G5** evaluation trigger | accepted as recommended | **IMPLEMENTED** — two freshnesses separated |
| **G6** `withheld` producer | **reconciliation required** | **IMPLEMENTED as amended** — no producer, no CHENV block, §2.3 |
| **G7** heartbeat replay | **reconciliation required** | **IMPLEMENTED as amended** — Health-authored epoch, §2.4 |
| **G8** store boundary | accepted as recommended | **IMPLEMENTED** — `/var/lib/kyri/health`, declared not created |
| **G9** collector identity | accepted as recommended | **IMPLEMENTED** — existing registry reused |
| **G10** `review_required` | accepted as recommended | **IMPLEMENTED** — conditionally required, stored |
| **G11** route degraded policy | accepted as recommended | **IMPLEMENTED** — `degraded` inert, `unavailable` subtracts |
| **G12** outcome attribution | **reconciliation required** | **IMPLEMENTED as amended** — attribution column, §2.5 |
| **G13** subject binding | accepted as recommended | **IMPLEMENTED** — three layers |
| **A1** first evaluation | accepted as recommended | **IMPLEMENTED** — not a transition |
| **A2** CHDEG naming | accepted as recommended | **IMPLEMENTED** — not renamed, clarified |
| **B** subject/dimension matrix | **reconciliation required** | **IMPLEMENTED as amended** — §2.6 |
| **C** adapter failure semantics | accepted as recommended | **IMPLEMENTED** — inverted consequence documented |

---

## 2. The six amendments, as implemented

### 2.1 G1 — a mechanically enforceable forward boundary

**The reviewer's requirement that changed the design:** *"New writes must not be
able to masquerade as legacy writes by omitting disclosure fields."*

My ENG-0006-B proposal could not satisfy that. It relied on write-time
enforcement in code, so a record's *shape* decided whether it was legacy — and a
new write omitting the fields was shape-identical to a legacy one. The reviewer's
amendment is a real correction, not a restatement.

**The implemented mechanism: a closed set of pre-disclosure identities.**

```yaml
health_disclosure_boundary:
  set: closed
  pre_disclosure_selection_ids:
    [CSEL-000001, CSEL-000002, CSEL-000003, CSEL-000004, CSEL-000005]
  disclosure_required_from: CSEL-000006
  global_schema_version_changed: false
  new_write_may_join_closed_set: false
```

**Why it cannot be masqueraded.** Selection identities are allocated from a
monotonic sequence under an exclusive lock, and that sequence **refuses rollover
rather than reusing a name**. Every identity a new write can receive is therefore
strictly greater than every member of the closed set. **Membership is decided by
identity, not by shape**, so omitting the disclosure fields buys no exemption: a
`CSEL-000006` without disclosure is not a legacy record, it is an invalid one.

**Why `schema_version` is untouched.** It is a single global value shared by all
eight Fabric families and enforced by equality — a stored record declaring a
different one is refused outright. Moving it would invalidate every
`capability-definition`, `contract`, `package`, `host`, `advertisement`,
`instance`, `route` and `selection` record in existence. `global_schema_version_
changed: false` is asserted in the schema and tested.

**Legacy records are read as what they are.** A record in the closed set reads as
`pre-disclosure-shape`. It is **not** read as `consulted: false` and **not**
assigned a default health state — `legacy_record_default_meaning: forbidden` —
because either would be this runtime asserting something about a decision taken
before the field existed. Nothing is written back.

**Disclosure is two-part, per the ruling.** Selection-level context (`consulted`,
`adapter_outcome`, `effect`, conditional `warning`) plus a per-candidate result
for **every considered candidate including the selected one**. The released record
gave an entry only to *excluded* candidates, which is why a winner health said
nothing about was indistinguishable from one health endorsed.

All nine health-input cases the ruling enumerates are distinguishable, and the
three that matter most — not consulted, consulted-and-silent, consulted-and-
healthy — are separated by `consulted` plus `health_state` plus a required
warning. `health_state` carries a `not-consulted` value precisely so the first
case is not spelled as a health state.

**Stale claim corrected.** `selection-visibility.md` asserted that the released
schema already carried the block. It did not, and now says so.

### 2.2 G4 — continuity: a gap is not a violation

**The reviewer's requirement:** *"Two observations separated by a long gap do not
establish continuous threshold violation. Define minimum coverage, maximum
permitted gap, and interval interruption/reset semantics."*

My ENG-0006-B proposal specified duration hysteresis and said nothing about gaps
— so two violating observations an hour apart would have satisfied a two-minute
duration. That is a real hole and the amendment closes it.

```yaml
hysteresis: { kind: duration, seconds: 120, max_gap_seconds: 30, min_samples: 3 }
```

All four members are **required**. An interval `[t0, t1]` satisfies the
hysteresis only when **all four** hold:

| Rule | Requirement |
|---|---|
| **Duration** | `t1 − t0 ≥ seconds` |
| **Violation throughout** | every **usable** observation in the interval violates the entry condition |
| **Minimum coverage** | at least `min_samples` usable observations in the interval |
| **Maximum gap** | no two consecutive usable observations more than `max_gap_seconds` apart, **and** the first within `max_gap_seconds` of `t0`, **and** the last within `max_gap_seconds` of `t1` |

A *usable* observation is `collection_status: collected`, with a
`measured_value`, within `freshness_policy_seconds`.

**Reset** moves `t0` to the next violating usable observation on: a usable
observation that does not violate; a gap between consecutive usable observations
exceeding `max_gap_seconds`; or a boundary gap exceeding it.

**The clause that does the security work:** `gap_cause_affects_reset: false` — **a
gap resets the interval regardless of why it exists**, whether nothing was
measured or only unusable observations were. That is "a collection failure is not
a capability failure" enforced arithmetically rather than promised in prose: a
monitoring outage leaves a gap in usable observations, the gap breaks continuity,
and **a monitoring failure therefore cannot manufacture a transition.**

**Reproducibility.** Six fields are promoted from optional to **required** on
every transition record — the resolved declaration, the achieved duration, the
first and last observation of the satisfying interval, the usable sample count,
and the largest observed gap. Every declared parameter has a matching *observed*
value beside it, so an operator recomputes the verdict from the record and the
cited observations without the evaluator. `unprovable_transition: refuse`.

Neither continuity parameter has a default: a defaulted one would be an
unanswered configuration question rendered as a confident assessment, which is the
mistake the Null Policy Rule exists to prevent.

### 2.3 G6 — `withheld` kept, producer deferred

**The reviewer's requirement:** *"preserve the state but do not introduce an
operational `withheld` producer. Do not add a CHENV publication-control block
merely to avoid a seventh family."*

My ENG-0006-B recommendation was the CHENV `publication` block, and I named its
cost — mixing a publication decision into a record whose job is limits. The
reviewer declined it. **No block was added.** The implemented position:

```yaml
withheld_semantics:
  v1_producer: none
  derivable_from_observations: false
  publication_authority: deferred-architecture
```

- The state and its eight semantic properties remain exactly as accepted.
- **No v1 mechanism produces it.** Derivation never emits it: it is the one state
  that is not a finding about a subject.
- **No implicit mapping from `availability_intent`**, stated in the ADR and
  tested.
- A future producer must be human-authorised, auditable, immutable or superseding,
  unable to mutate Fabric, and unable to masquerade as evidence-derived health.
  Whether that is a seventh family or a field is not decided here.

### 2.4 G7 — the epoch is Health-authored

**The reviewer's requirement:** *"Epoch advancement must be bound to an
authenticated, verifiable session or restart event. It must not become an
unverified replay bypass."*

This caught a genuine hole in my proposal. I had `epoch` subject-asserted, which
means a subject could replay an old sequence simply by claiming a new epoch — the
replay protection would have been decorative.

**Implemented: the epoch is Health-authored and bound to the authenticated
session the heartbeat arrived in.**

| Field | Author | Role |
|---|---|---|
| `observed_at` | subject | a claim, retained for audit, **never** an input to freshness |
| `received_at` | **Health** | the **only** input to `heartbeat-freshness` |
| `epoch` | **Health** | bound to the authenticated session, monotonic per subject |
| `sequence` | subject | must strictly increase within an epoch |

`epoch_self_advancement: forbidden`. A restart advances the epoch **only by
re-authenticating**, and establishing an authenticated session is itself evidence
that something is alive — so a genuine restart is admitted and a passive replay
is not. A pair already seen is refused and the refusal recorded, so **a replay
never acquires a `received_at`**. `subject_id` is bound to the authenticated
channel identity, or any subject could heartbeat on another's behalf.

**Bounded liveness, never a complete conclusion.** The ruling's wording is
implemented literally:

```yaml
supports: bounded-liveness-only
alone_supports_healthy: false
```

and on the state:

```yaml
healthy_requires_independent_evidence: true
subject_reported_dimensions_alone_support_healthy: false
envelope_of_only_subject_reported_dimensions: insufficient-policy
```

> **INDEPENDENT-EVIDENCE INVARIANT.** `healthy` requires at least one satisfied
> dimension established by an observation whose `collector_id` is **not the
> subject itself**.

An envelope declaring only subject-reported dimensions yields
**`insufficient-policy`** — it has not declared enough to tell "alive" from
"working". That reuses an existing state rather than inventing a mechanism, and it
is visible and inert.

### 2.5 G12 — attribution before any negative finding

**The reviewer's requirement:** *"Do not automatically attribute adapter,
interruption, serialization or other ambiguous failures to the capability
instance. Define how attributable capability failures are separated from
platform-side failures before they can contribute to a negative Health finding."*

My ENG-0006-B mapping had two columns and would have counted `adapter-error`,
`timeout`, `interrupted` and `serialisation-failure` as `failure` without asking
whose failure. **A third column — attribution — is now normative**, and the
eight-class inventory and the three-way success/failure/neither mapping are
retained as ruled:

| `outcome_class` | Counts as | Attribution |
|---|---|---|
| `completed` | success | capability-instance |
| `refused` | **neither** | platform-governed |
| `cancelled` | **neither** | external-decision |
| `provider-error` | failure | **capability-instance** |
| `adapter-error` | failure | platform-side |
| `timeout` | failure | **ambiguous** |
| `interrupted` | failure | **ambiguous** |
| `serialisation-failure` | failure | platform-side |

```yaml
failure_count_counts: subject-attributable-only
platform_side_failures_count: never
ambiguous_failures_count: never
```

**Only `provider-error` reaches `failure-count`.** An adapter or serialisation
failure is **Kyri's**, and reading it as the subject's is the same mistake as a
collector reporting its own outage as the host being broken. A `timeout` may be a
hanging provider or a misconfigured supervisor; an `interrupted` may be the host,
the supervisor or a signal — and nothing in the released record distinguishes
them, so **neither is attributed**. I applied the ruling's principle
conservatively rather than inventing an attribution rule for them.

The boundary direction is unchanged and still enforced by name: the Capability
Runtime pushes nothing, and a Health-side collector reads `capability-result`.

### 2.6 B — the subject/dimension matrix, and integrity separated

**The reviewer's requirement:** *"Packages cannot have runtime liveness, latency
or resource-pressure health. Separate package integrity and verification evidence
from operational Health… Review every Health family for consistent subject
constraints."*

**The matrix is declared** on the observation schema as `dimension_subjects`,
rather than left to a collector's judgement. Every runtime dimension —
availability, heartbeat-freshness, transport-health, latency, queue-depth,
success-count, failure-count and all five resource-pressure dimensions — admits
`capability-instance` and `capability-host` only.

**`capability-package` is removed as a subject from all six Health families.** It
was previously admitted by five of them and absent only from the heartbeat, which
was the inconsistency the ruling asked me to review. A package is not a running
thing; an `availability` observation about one is a claim about something that
does not run, and the architecture's own argument for dropping `lease-health` and
`placement-health` applies — a schema whose subject does not exist is a dangling
reference. The three Health relationship edges targeting subjects were narrowed to
match, so the ontology and the schemas agree.

**Package integrity is pointed at the Integrity plane, not relabelled as health.**
`observation-model.md` now states that package integrity and verification evidence
answer a different question from whether a live instance is working, and that
collapsing them would let a verified package read as an available one. **Defining
that evidence in the Integrity plane is outside this increment** and is recorded
in §7.

---

## 3. Normative changes applied

**ADR-0013** — amended, with an amendment header naming what changed and why.
Three self-contradictions corrected in place, each naming the text it replaces
rather than quietly overwriting it: the state count and table (C1), the
recommendation vocabulary (C2), the `withheld` row (C3). Six new normative
sections: collector identity and contradicting sources (G9); execution outcomes
with the attribution table (G12); the heartbeat trust model and the
independent-evidence invariant (G7); withheld publication authority deferred
(G6); what subtracts (G11); when a state is derived and which freshness it
carries (G5); the Health store and authority boundary (G8); referential integrity
(G13). Two clarifications inside degradation semantics: a first evaluation is not
a transition (A1), and the record is named for degradation and records every
transition (A2).

**ADR-0019 — new** (294 lines): the Health condition and hysteresis grammar.
Five comparison operators, decimal-string values, a dimension/unit table,
`instant` and `windowed_count` aggregation, half-open window boundaries reusing
the route's existing convention, duration-only hysteresis with the four
continuity rules, the six required proof fields, ordering, and an explicit
statement that **no rounding rule is required because the grammar performs no
division**. Percentiles are excluded with the reasoning, and the worked example
is corrected rather than supported.

**ADR-0012** — amended: health disclosure on a selection, the closed forward
boundary, and a restatement of which states subtract, since the Fabric is what
honours it.

**Schemas (7).** `capability-health-envelope` — structured conditions, operator
set, aggregations, unit table and mismatch refusal, hysteresis kinds and the
continuity block; package removed. `capability-health-observation` —
`collector_id` and `source_fingerprint` required, free-text `source` **forbidden**,
closed-registry constraint, contradiction rule, attribution rules, the
dimension/subject matrix; package removed. `capability-health-state` — the two
freshnesses, evaluation trigger, first-evaluation rule, independent-evidence
invariant, subject binding, `review_required` conditionally required, withheld
producer `none`; package removed. `capability-degradation-event` — six hysteresis
proof fields promoted to required, continuity, subject binding, first-evaluation,
naming; package removed. `capability-heartbeat` — `received_at`, Health-authored
`epoch`, `sequence` promoted to required, monotonicity, replay and identity
binding rules. `capability-health-recommendation` — header prose corrected to its
own enum, subject binding; package removed. `capability-selection` — the
disclosure block, the per-candidate structure, and the closed forward boundary.

**Ontology.** Two new relationship types, `DERIVED_FROM_OBSERVATIONS` and
`FOLLOWS_FROM_STATE`, each carrying `same_subject_required: true`. **`DERIVED_FROM`
and its four forbidden pairs are untouched** — the dedicated edges name no trust
type at either end, so a Trust↔Health derivation cannot be expressed on them
however they are widened later. The three subject-targeting Health edges narrowed
to instance and host. `entity-types.yaml` — the recommendation description
corrected to the closed four-value vocabulary.

**Health documentation (8).** `health-states.md`, `selection-visibility.md`,
`operational-envelope.md`, `degradation-semantics.md`, `observation-model.md`,
`unknown-and-freshness.md`, `governance-boundaries.md`, `worked-examples.md`,
`capability-health.md`.

**Roadmap.** The Health relationship count corrected from four to six, with the
reason, since two edges were added.

---

## 4. RED/GREEN evidence

The agreement suite was written **first**, against unmodified artefacts.

| Run | Result |
|---|---|
| **RED** — before any normative change | **32 PASS / 55 FAIL**, exit 1 |
| GREEN interim — after corrections, before test-bug fixes | 80 PASS / 8 FAIL |
| **GREEN** — final | **88 PASS / 0 FAIL**, exit 0 |

**The RED run is the proof that these were genuine inconsistencies**, not
cosmetic tidying. A sample of what failed before and passes now:

- the state set disagreed across ADR-0013, `health-states.md`, the CHSTATE enum
  and both CHDEG enums — **five independently authored sources**
- the recommendation vocabulary disagreed across three sources, and ADR-0013
  named a value no schema permits
- **no governed edge permitted** `CHSTATE → CHOBS`, `CHDEG → CHOBS` or
  `CHREC → CHSTATE`, which three schemas require as fields
- the CSEL schema declared no disclosure block while `selection-visibility.md`
  claimed it did
- CHOBS required a free-text `source` while the released `observation` schema
  next to it required `collector_id` and `source_fingerprint`
- CHDEG's hysteresis evidence was **optional**, so an unprovable transition was
  writable
- five of six Health families admitted `capability-package` as a subject

**The 32 assertions that passed in RED matter too** — they prove the suite is not
vacuous. It confirmed from the start that the `withheld_semantics` block was
already correct, that no edge connected Trust and Health in either direction, that
the route's uniform health invariants were intact, and that no Health schema
permitted trust mutation or execution.

**Eight interim failures, honestly accounted for.** Three were my own test bugs:
first-column extraction that did not strip bold markers, reading the effect column
at index 4 when the table has four columns, and a regex matching `recomputed` when
the document says `recomputes`. One was an **inverted assertion** — I had grepped
for bare `drain` in ADR-0013 and both matches were statements that drain is *not*
permitted, so the check was asserting the opposite of its intent; it is now a
positive assertion. The remaining three were a real design tension: my correction
notes quoted the exact stale phrases, and the tests check those phrases are
absent. I reworded the notes to **describe** the prior error without reproducing
the normative phrase, so the grep stays meaningful as a guard against the phrase
returning — the notes still name what was wrong.

**Two pre-existing suites failed and were handled differently, on purpose.**

- `observation requires source` encoded the **superseded** position. G9 is
  approved, so the assertion moved to `collector_id` + `source_fingerprint`, plus
  two new assertions that free-text `source` is forbidden and the identity comes
  from the closed registry.
- `health documentation asserts runtime behaviour: is running` was a **false
  positive from my own prose**: I wrote "is this running thing working", and the
  guard's literal `is running` matches inside "th**is running**". **I reworded my
  sentence rather than weaken a pre-existing safety guard**, and verified the
  guard is still armed.

**The parity suite caught an omission I had not noticed.**
`test-developer-experience.sh` failed with *"test suites exist that local
validation never runs: test-capability-health-agreement.sh"*. The new suite is now
registered in `run-validation.sh` (step counts 142→143 and 167→168) and in CI.
A suite that is green because nothing runs it is the same defect class as a suite
that is green because it reads one artefact.

---

## 5. All test results

| Suite | Result |
|---|---|
| `test-capability-health-agreement.sh` **(new)** | **88 assertions, all passed** |
| `test-capability-health.sh` | **464 assertions, all passed** (was 461; +3) |
| `test-docs-static.sh` | passed |
| `test-static.sh` | passed |
| `test-platform-model.sh` | passed |
| `test-developer-experience.sh` | passed |
| ShellCheck (new + modified shell files) | clean, exit 0 |
| `run-validation.sh --quick` | **halts at step 16 on a pre-existing failure** — see §5.1 |
| `run-validation.sh` (full) | not reachable past step 16 — see §5.1 |

### 5.1 Three pre-existing suite failures, and how I proved they are not mine

**The validator cannot complete at this baseline, and not because of this
increment.** It halts at step 16, `Capability execution generation-12 installer`,
with 26 failed assertions.

**Proof that it pre-exists.** I stashed every ENG-0006-C change, leaving the tree
byte-identical to the reviewed `5a4f559`, and ran the same suite: **26 failures,
exit 1 — identical.** Restored and re-ran: identical again.

I then ran **every suite that reads any artefact this increment touched** — 40
suites found by grepping for `platform-model`, `docs/health`, `docs/decisions`,
`relationship-types` and `entity-types` — both with my changes and at the stashed
baseline, comparing **exit codes**:

| | With ENG-0006-C | At reviewed baseline |
|---|---|---|
| Suites passing | 38 / 40 | 38 / 40 |
| Nonzero exit | `test-artifact-authority.sh`, `test-fabric-evidence-authority.sh` | **the same two** |

A diff of the two failing sets is **empty**: **ENG-0006-C introduces no new
failure.**

**The three pre-existing failures**, with their fault shape:

| Suite | Failures | Shape |
|---|---|---|
| `test-capability-execution-generation12-installer.sh` | 26 | builds its fixture from historical commits via `git show`; expects 70 installed objects and finds 57 |
| `test-artifact-authority.sh` | 10 | `stat: cannot statx …/var/lib/kyri/artifacts/…/main.py: No such file or directory` |
| `test-fabric-evidence-authority.sh` | 7 | `stat: cannot statx …/var/lib/kyri/evidence/EVID-000001.yaml: No such file or directory` |

All three fail while constructing temporary fixtures, and none touches Health,
the Health schemas, the ontology or any artefact in this change set. They are
**out of scope for ENG-0006-C** and are reported rather than fixed — repairing a
Generation-12 installer fixture inside a Health architecture increment would be
exactly the kind of unrelated change that makes a diff unreviewable. They need
their own increment.

**A verification mistake of my own, corrected.** My first sweep reported "0
failures" because I grepped each suite's last output line for the word *fail* —
and two of those suites end on a `stat` error line rather than a verdict, so a
nonzero exit was invisible to the check. I re-ran the sweep on **exit codes**,
which is the signal that cannot be ended on by noise, and that is what the table
above reports. The first method would have let me claim a clean sweep that was
not clean.

---

## 6. Compatibility analysis

**No existing immutable record is rewritten. EXISTING_RECORD_REWRITE_REQUIRED = NO.**

| Record family | In production | Impact |
|---|---|---|
| `capability-selection` | **5** | **None.** Byte-identical, still loadable, named in the closed pre-disclosure set, read as pre-disclosure rather than assigned a default meaning |
| `capability-route` | 7 | **None.** No route schema field added; the health invariants are unchanged |
| `capability-instance` | 7 | **None** |
| `capability-advertisement` | 8 | **None** |
| `capability-host`/`-package`/`-contract`/`-definition` | 1 each | **None** |
| `capability-invocation` | 3 | **None** |
| `capability-result` | 2 | **None.** Read-only; the mapping adds no field |
| Trust records | — | **None.** Neither read as health evidence nor written |
| `CADM`/`CMUT` | 7 / 12 | **None** |
| Health records | **0** | n/a — no store exists |

**The global Fabric schema version is unchanged:** `schott-platform/v1`, asserted
in the selection schema as `global_schema_version_changed: false` and tested.

**One schema change narrows an enum on a populated family:**
`capability-package` was removed as a Health `subject_type`. **No record is
affected**, because no Health record exists. The `capability-package` record
itself is untouched — it simply has no operational health, which is the ruling's
position.

**Forward-only boundaries introduced:** one, on `capability-selection`. Old
records remain valid under the shape that created them.

---

## 7. Deferred and unresolved

Recorded rather than invented, per the ruling's instruction to document options
and stop rather than invent policy.

| # | Item | Status | Why it is not decided here |
|---|---|---|---|
| **D1** | `withheld` publication authority | **deferred by ruling** | The ruling directs that no producer be introduced in v1. A future one must be human-authorised, auditable, immutable or superseding, unable to mutate Fabric, and unable to masquerade as evidence-derived health; whether that is a seventh family or a field on an existing one is open. |
| **D2** | `timeout` and `interrupted` attributability | **deferred** | Both are genuinely ambiguous and the released record carries nothing distinguishing a hanging provider from a misconfigured supervisor. They are excluded from `failure-count`. Making either attributable requires new evidence and its own decision. |
| **D3** | A platform-side failure dimension | **deferred** | A platform-side failure rate is a fact about Kyri, not the subject. It belongs with the observability-of-the-observer dimensions, and a defensible envelope for it does not exist — a dimension whose threshold nobody can justify would be `insufficient-policy` by construction. |
| **D4** | Package integrity evidence in the Integrity plane | **deferred — outside this increment** | The ruling requires package integrity be *separated* from operational Health, which is done: package is no longer a Health subject and the documentation points at the Integrity plane. **Defining that evidence is new Integrity-plane architecture** and was not in scope. Until it exists, package integrity has a declared owner and no record. |
| **D5** | The heartbeat transport authentication mechanism | **dependency, not a gap** | The *binding* is specified — the epoch is bound to the authenticated session and `subject_id` to the authenticated channel identity. **How the channel is authenticated is transport architecture** and is not invented here. The G7 replay protection is only as strong as that mechanism, and this is stated so the dependency is visible rather than assumed. |
| **D6** | Percentile aggregation | **deferred, additive** | Excluded from v1 with reasoning. A future `percentile` aggregation with a named interpolation convention invalidates no envelope written under ADR-0019. |
| **D7** | Route-level health policy (G11 option A) | **deferred, additive** | `degraded` is inert because the condition the architecture placed on its removal has no referent. Adding an explicit route policy later would activate selective subtraction without invalidating anything written now. |

**None of these blocks the Health Runtime implementation plan.** D5 blocks the
heartbeat receiving surface specifically, and should be resolved before that
increment rather than before the plan.

---

## 8. Cross-artefact test design, and what it is for

The suite is a separate file with one rule, stated in its header and enforced by
review rather than by machinery:

> **Every assertion must extract the same fact from two or more independently
> authored artefacts and compare them.**

An assertion that reads one artefact belongs in the other suite. The reason is
recorded in the file: the existing 461-assertion suite asserted
`len(health_states) == 7` **from the CHSTATE schema** and was green while
ADR-0013 declared six, because nothing compared them. That is the ENG-0005 **F4**
class — a test that proves the artefact it was derived from — and a conflict
visible in two files survived a passing suite for two months.

| ID | Fact | Independently authored sources compared |
|---|---|---|
| **T1** | health-state vocabulary | ADR-0013 table · `health-states.md` table · CHSTATE enum · CHDEG `from_state` · CHDEG `to_state` — **5** |
| **T2** | recommendation vocabulary | ADR-0013 · `governance-boundaries.md` · CHREC enum — **3**, plus `drain` permitted nowhere |
| **T3** | `withheld` semantics | ADR-0013 row · `health-states.md` · `withheld_semantics` |
| **T3b** | `withheld` producer deferred | ADR-0013 · CHENV (absence of a publication block) · CHSTATE |
| **T4** | operators, aggregations, units | ADR-0019 · CHENV · CHOBS dimensions · `worked-examples.md` — **4** |
| **T5** | hysteresis kinds and proof fields | ADR-0019 · CHENV · CHDEG required fields |
| **T6** | relationship edges | ontology · the three citing schemas, **and no Trust↔Health edge in either direction** |
| **T7** | CSEL disclosure and boundary | `selection-visibility.md` · CSEL schema · the five production identities |
| **T8** | the two freshnesses | ADR-0013 · `unknown-and-freshness.md` · CHSTATE |
| **T9** | which states subtract | ADR-0013 · `health-states.md` · route schema invariants |
| **T10** | subject binding | three schemas · ontology `same_subject_required` |
| **T11** | outcome mapping | ADR-0013 table · released `OUTCOME_CLASSES` — all **8** covered, attribution checked |
| **T12** | collector identity | CHOBS · released `observation` schema · `observation-model.md` |
| **T13** | Null Policy Rule | Confidence and Freshness Standard · CHSTATE |
| **T14** | store boundary | ADR-0013 · `governance-boundaries.md` · all six schemas |
| **B** | subject/dimension matrix | CHOBS dimensions · the matrix · all six families' `subject_type` |

**T6 closes a gap I found in my own ENG-0006-B analysis.** `DERIVED_FROM`'s
forbidden pairs guard *source trust → target health*; the symmetric direction was
unguarded. The test now asserts **both** directions across every relationship
type, so the asymmetry cannot return through a future widening.

**The agreement helper reports which sources disagreed and what each said**, not
merely that they differ — a diff that says only "mismatch" sends a reader back to
re-derive what the test already knows.

---

## 9. Production state — unchanged

Confirmed explicitly, as required.

| | |
|---|---|
| Production Fabric | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` — **unchanged** |
| Production Capability Runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` — **unchanged** |
| Production Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` — **unchanged** |
| Health store | **does not exist** — none created |
| Health records anywhere | **0** |
| Runtime code changed | **none.** The only file under `tools/` is `tools/dev/run-validation.sh`, a developer validation driver, not runtime |
| Provisioning changed | **none** |
| Immutable records rewritten | **none** |
| Global Fabric schema version | `schott-platform/v1` — **unchanged** |
| ENG-0005 branch | `0f36074fa2679cb555cc1d22a7cf14d0475543a3` — untouched |
| `v0.11.0` | → `ce0debb8be3c87babf6856fb7f694c590fc667a1` — untouched |
| Merged or deployed | **no** |

---

## 10. Result

```
RESULT=REVIEW_REQUIRED
INCREMENT=ENG-0006-C
BRANCH=arch/eng-0006-health-runtime
STARTING_HEAD=5a4f55984ae5299530382d29ede48ef3e10473ea
APPROVED_DECISIONS_IMPLEMENTED=20
AMENDMENTS_IMPLEMENTED=6
ADR0013_EDITED=YES
ADR0012_EDITED=YES
NEW_ADR=ADR-0019-health-condition-grammar
SCHEMAS_EDITED=7
ONTOLOGY_EDITED=YES
CROSS_ARTIFACT_TESTS_IMPLEMENTED=15
RED_BEFORE=32_PASS_55_FAIL
GREEN_AFTER=88_PASS_0_FAIL
NEW_FAILURES_INTRODUCED=0
PRE_EXISTING_FAILURES_OBSERVED=3
HEALTH_RUNTIME_IMPLEMENTED=NO
HEALTH_STORE_CREATED=NO
EXISTING_RECORD_REWRITE_REQUIRED=NO
GLOBAL_FABRIC_SCHEMA_VERSION_CHANGED=NO
RUNTIME_CODE_CHANGED=NO
PRODUCTION_FABRIC_MUTATION=NONE
PRODUCTION_CAPABILITY_MUTATION=NONE
PRODUCTION_TRUST_MUTATION=NONE
PRODUCTION_HEALTH_MUTATION=NONE
UNRESOLVED_DECISIONS=7_DEFERRED
MERGED=NO
PUSHED=NO
NEXT=independent reviewer evaluates the ENG-0006-C reconciliation
STOP
```

**What the reviewer should look at first.** The six amendments in §2 are where my
ENG-0006-B recommendations were changed, and three of them closed real holes I had
left: G1's boundary was enforceable only in code and a new write could have
masqueraded as legacy; G4 specified a duration with no gap semantics, so two
observations an hour apart would have satisfied a two-minute hysteresis; and G7's
epoch was subject-asserted, which made the replay protection decorative. The
amendments are improvements, not restatements.

**Also worth a look:** §5.1, where three suites fail for reasons that pre-date this
increment and need their own work; and §7, where seven items are deferred rather
than guessed — including **D5**, the heartbeat transport authentication mechanism,
which the G7 replay protection ultimately rests on and which is not specified
anywhere.

## Related

- [ENG-0006-B resolution package](2026-10-13-eng-0006-b-architecture-resolution-package.md)
- [ENG-0006-A reconciliation](2026-10-12-eng-0006-a-architecture-reconciliation.md)
- [ADR-0013: The Capability Health Plane](../../../decisions/ADR-0013-capability-health-plane.md)
- [ADR-0019: The Health Condition and Hysteresis Grammar](../../../decisions/ADR-0019-health-condition-grammar.md)
- [ADR-0012: The Distributed Capability Fabric](../../../decisions/ADR-0012-distributed-capability-fabric.md)
