# ENG-0006-A — Health architecture reconciliation and implementation readiness

**Date:** 2026-10-12 · **Branch:** `arch/eng-0006-health-runtime`
**Baseline:** `main` at `5c7ff9abed3dce628218b78ad9d4610d886023d8`
**Released prerequisite:** `v0.11.0` → `ce0debb8be3c87babf6856fb7f694c590fc667a1`

**RESULT: REVIEW_REQUIRED.** Discovery and specification only. No runtime code,
no provisioning, no production record of any kind.

**ADR-0013 status: CONFLICTS_FOUND.** Three conflicts, ten gaps. The Health
architecture is substantially sound and unusually well defended — its governance
boundaries, its treatment of `unknown`, and its refusal of a health score are all
reconcilable against the released platform without change. It is **not yet
implementable as written**, for two reasons that are different in kind:

1. **ADR-0013 contradicts itself and its own schemas in three places.** Each is
   residue of a superseded draft, and in each case the schemas and the subsidiary
   documents agree with each other against the ADR.
2. **The architecture requires determinism it does not specify the means for.**
   `entry_condition`, `exit_condition` and `hysteresis` are required fields with
   no declared grammar. A deterministic evaluator cannot be built on free text,
   and choosing the grammar chooses the policy surface — which is exactly the
   decision ADR-0013 reserves to a human.

Nothing here is resolved. Every conflict and gap below carries a proposed
smallest resolution and an `ADR_CHANGE_REQUIRED` marker, for the reviewer to
accept, amend or reject.

---

## A. Does ADR-0013 plus `docs/health/` still form an implementable architecture?

**Internally consistent: no.** Three conflicts, §C.
**Complete against released v0.11.0: no.** Ten gaps, §D.
**Implementable after those are resolved: yes**, and with less change than the
count suggests. Eight of the thirteen findings are resolvable by correcting
documents to match schemas that are already right.

What survives reconciliation unchanged is worth stating first, because it is the
larger part and it constrains everything proposed later:

| Architectural claim | Released surface | Verdict |
|---|---|---|
| Health cannot grant eligibility | `tools/fabric/eligibility.py` — twelve conditions `ELIG-1`…`ELIG-12`, **none of them health** | **CONSISTENT** |
| Quarantine always wins | quarantine is `ELIG-10`, evaluated before any selection-stage removal | **CONSISTENT** |
| Health cannot override `availability_intent` | `eligibility.py:624` requires `availability_intent == in-service`, independent of health | **CONSISTENT** |
| Health may only remove a candidate | `selection.py:370` adds `REASON_HEALTH_REMOVED` as an exclusion, after eligibility; there is no additive path | **CONSISTENT** |
| Health cannot reorder candidates | removal is set-membership; declared order is untouched | **CONSISTENT** |
| Health cannot mutate Trust | `DERIVED_FROM.forbidden_source_target_pairs` bars trust-record and trust-decision from citing `capability-health-observation` or `capability-health-state` | **CONSISTENT** |
| The Capability Runtime cannot reach Health | `tests/test-capability-runtime.sh:143-145` forbids `tools.health`, `..health`, `liveness`, `readiness`, `heartbeat` **by name** | **CONSISTENT** |
| Health history is immutable and append-only | all six schemas: `mutability: immutable`, `supersession: new-record-only`, `append_only_history: true` — the same contract the released `ImmutableStore` implements | **CONSISTENT** |
| Identifier allocation | `CHENV` 4-digit, the other five 6-digit; the released `id_widths` + flock'd `.seq` read-modify-write in `tools/fabric/store.py:381` supports both and refuses rollover rather than reusing a name | **CONSISTENT** |
| Freshness vocabulary | `current` · `aging` · `stale` · `unknown`, reused rather than redefined, per the Confidence and Freshness Standard | **CONSISTENT** |

**The single most important consistency**, because it is the one a future
implementer is most likely to break: the released Fabric already applies health
as a *subtraction after eligibility*, never as an input to it. The hook is
`health_removals` on `select_candidate`, and it takes an opaque set of
`capability-instance` identifiers. The Fabric does not read health records and
must not start.

---

## B. Health schemas present in platform-model

**HEALTH_SCHEMAS_FOUND = 6.** All six accepted families exist, with six matching
ontology entity types and four relationships.

| Family | Schema | `id_pattern` | Entity type | Matches prose? |
|---|---|---|---|---|
| CHENV | `capability-health-envelope.schema.yaml` | `^CHENV-[0-9]{4}$` | present | **Yes** |
| CHBEAT | `capability-heartbeat.schema.yaml` | `^CHBEAT-[0-9]{6}$` | present | **Yes** |
| CHOBS | `capability-health-observation.schema.yaml` | `^CHOBS-[0-9]{6}$` | present | **Yes** |
| CHSTATE | `capability-health-state.schema.yaml` | `^CHSTATE-[0-9]{6}$` | present | **Yes**, and it is the ADR that disagrees |
| CHDEG | `capability-degradation-event.schema.yaml` | `^CHDEG-[0-9]{6}$` | present | **Yes** |
| CHREC | `capability-health-recommendation.schema.yaml` | `^CHREC-[0-9]{6}$` | present | **No** — its header prose names two recommendation kinds, its enum declares four |

**The direction of disagreement matters.** On all three conflicts in §C the
schemas hold the corrected position and ADR-0013 holds the superseded one. That
is the opposite of the usual case, and it means the resolution is almost entirely
a documentation correction rather than a schema change.

**A released test asserts the corrected position already.**
`tests/test-capability-health.sh:423` asserts `len(health_states) == 7`, reading
the schema. The suite passes — **461 assertions**, all green at this baseline —
and it has never compared the schema to ADR-0013's own table. That is why a conflict
this visible has survived: **every assertion checks the artefact that agrees with
it.** This is the F4 defect class carried forward from ENG-0005, and it is worth
naming here because the Health test strategy in §K is the place to not repeat it.

---

## C. Specification conflicts

**SPECIFICATION_CONFLICTS = 3.** All three are internal to ADR-0013.

### CONFLICT-1 — ADR-0013 declares six health states; everything else declares seven

| | |
|---|---|
| **Classification** | SPECIFICATION_CONFLICT |
| **ADR-0013** | line 153: "**Six states.** `unknown` is the default." Table at lines 155–162 omits `insufficient-policy`. |
| **Contradicted by** | `docs/health/health-states.md`: "Seven states", seven-row table including `insufficient-policy` · `docs/health/operational-envelope.md`: "A metric with no declared threshold produces `insufficient-policy`, never `healthy`" · `docs/health/worked-examples.md` example 6 · `docs/health/selection-visibility.md` warning list |
| **And by its own schemas** | `capability-health-state` `state` enum: 7 values · `inert_states` includes `insufficient-policy` · `capability-degradation-event` `from_state`/`to_state`: 7 values each · `capability-health-envelope`: `absent_threshold_means: insufficient-policy` |
| **And by ADR-0013 itself** | line 379 — "`unmonitored` and `insufficient-policy` are visible **states** rather than quiet passes". The ADR names the seventh state in its own Accepted Consequences while omitting it from its state table. |
| **Released runtime surface** | `tests/test-capability-health.sh:423` asserts exactly seven, against the schema |
| **Why implementation cannot guess** | ADR-0013 is the governing document and the state set is its most load-bearing enumeration. Implementing seven contradicts the governance; implementing six breaks four documents, two schemas and a passing released assertion. Neither is a judgement call an implementer may make silently. |
| **Smallest resolution** | Correct ADR-0013 line 153 to "Seven states" and add the `insufficient-policy` row to the table at 155–162, with the meaning already given in `health-states.md` and the schema. **No semantic change** — the ADR already describes the per-metric Null Policy Rule and already calls the state visible. |
| **ADR_CHANGE_REQUIRED** | **YES** |

### CONFLICT-2 — ADR-0013 declares a two-kind recommendation vocabulary; the schema declares four, and the two do not intersect cleanly

| | |
|---|---|
| **Classification** | SPECIFICATION_CONFLICT |
| **ADR-0013** | line 244: "It may recommend **`investigate`** or **`drain`**. Nothing else." |
| **Contradicted by** | `docs/health/governance-boundaries.md`: "a **closed vocabulary of exactly four**" — `investigate`, `review-envelope`, `verify-observation-source`, `consider-manual-drain` · `capability-health-recommendation` `recommendation` enum: the same four |
| **The sharp edge** | **`drain` is not a permitted value anywhere.** The schema's value is `consider-manual-drain`, and the distinction is the entire point — `governance-boundaries.md` writes "**Consider, not do**", and ADR-0013's own prose two paragraphs later says the Monitor "may recommend investigation or draining" while `may_execute: false`. An implementer following line 244 literally would emit a value the schema rejects, and would have named an act rather than a consideration. |
| **Also internally stale** | the CHREC schema's own header comment repeats the two-kind phrasing while its enum declares four. |
| **Released runtime surface** | none — no runtime writes CHREC. The conflict is pre-implementation, which is the cheapest time to find it. |
| **Why implementation cannot guess** | The vocabulary is declared **closed** precisely so that it cannot be extended by inference. An implementer cannot resolve a closed-vocabulary conflict by picking the longer list; and the missing two kinds (`review-envelope`, `verify-observation-source`) carry real architectural content — they are how the layer says "the measurement may be wrong" rather than "the subject is broken", which is the collection-failure distinction applied to advice. |
| **Smallest resolution** | Correct ADR-0013 line 244 to the four closed values, naming `consider-manual-drain` rather than `drain`. Correct the CHREC header comment to match its enum. |
| **ADR_CHANGE_REQUIRED** | **YES** |

### CONFLICT-3 — ADR-0013's `withheld` table row restates the definition the ADR itself repudiates

| | |
|---|---|
| **Classification** | SPECIFICATION_CONFLICT |
| **ADR-0013** | line 162: "`withheld` \| The operator set the host's availability intent to draining or withheld." |
| **Repudiated by ADR-0013 itself** | the section immediately following, *"Withheld is not the Fabric's availability intent"*: "These were the same thing in the first draft of this ADR, and that was wrong in a way worth recording… it makes a *health state* into a *selection control*." |
| **And by** | `health-states.md`: "`withheld` means health conclusions are intentionally not asserted or published" · `capability-health-state` `withheld_semantics.means: health-conclusion-not-asserted-or-published`, with `removes_eligibility: false` and `may_set_availability_intent: false` |
| **Why implementation cannot guess** | The two readings produce opposite runtime behaviour. Under line 162 `withheld` is derived from a Fabric field and is a selection control; under the corrected definition it is a Health publication decision that removes nothing. An implementer who reads the table and stops has built the exact defect the ADR documents itself having fixed. |
| **Smallest resolution** | Replace the line-162 cell with the corrected meaning. The row is residue; the ADR's own next section is already the decision. |
| **ADR_CHANGE_REQUIRED** | **YES** |

---

## D. Specification gaps

**SPECIFICATION_GAPS = 10.**

### GAP-1 — Selection visibility is not implementable on the released selection record

**The most consequential finding in this report.**

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Requires** | `docs/health/selection-visibility.md`: "**Every Capability Selection must expose**" — referenced Health state, health freshness, whether Health changed eligibility, explanation, envelope version, and a warning when the state is `unknown`, stale, `withheld` or `insufficient-policy`. ADR-0013: "**Health must never silently disappear from the explanation.**" |
| **Claims** | the same document: "The Fabric's selection schema **carries the requirement as a declared block**." |
| **Released surface** | `platform-model/schemas/capability-selection.schema.yaml` carries **no such block**. The only occurrence of health in it is `health_score`, in `forbidden_fields`. |
| **Production evidence** | `CSEL-000001`…`CSEL-000005` exist. `CSEL-000005` has fourteen top-level fields and **not one health field** — no state, no freshness, no effect, no warning, no envelope version. |
| **What the runtime does record** | `select_candidate` folds `health_removals` into the **request digest**, so a health input is an authoritative governed input, and records health's *effect* as the exclusion reason `candidate-removed-by-health-input` on a removed candidate. |
| **The precise hole** | there is **no representation for "health was consulted and had nothing fresh to say"**. That is the case ADR-0013 and `selection-visibility.md` single out as the one that must be conspicuous, and in the released record it is byte-identical to a selection where health was never consulted at all. `selection-visibility.md`'s own three-case table says the second and third cases "produce the same eligibility outcome and mean opposite things" — and the released record cannot tell them apart. |
| **Why implementation cannot safely guess** | Both obvious resolutions are wrong in different ways. Adding **required** fields to a released immutable schema invalidates five production records, which **invariant 18 forbids**. Adding **optional** fields satisfies the schema and not the architecture: optional-and-absent *is* the silent case, so a runtime could emit a conforming selection that says nothing about health and still pass. The resolution has to make the health block mandatory **from a declared version forward** without reaching back, and that is an ADR-0012/ADR-0013 boundary decision about a released record. |
| **Smallest resolution to consider** | A `health_disclosure` block, conditionally required from a declared `schema_version` forward, carrying `health_state`, `health_freshness`, `health_effect` ∈ {`removed`, `none`}, `health_warning` (required whenever the state is not `healthy`), and `envelope_version` where applicable — with the existing five records explicitly out of scope as pre-disclosure records, recorded as such rather than migrated. This mirrors the `route_provenance: all-or-none` pattern the schema already uses for a conditionally-required group. |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** — it changes a released ADR-0012 record to satisfy an ADR-0013 requirement, and which ADR owns the change is the reviewer's call. |

### GAP-2 — The evidence citation chain has no relationship edge

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Requires** | CHSTATE and CHDEG both **require** `derived_from_observation_ids`; CHREC **requires** `derived_from_state_id`. ADR-0013 Audit requirements: "States carry the observation identifiers they were derived from, so the evidence behind any past assessment stays reachable." |
| **Released surface** | `platform-model/ontology/relationship-types.yaml`. `DERIVED_FROM.allowed_sources` = `[verification, knowledge-event, observation, trust-record, trust-decision]` — **no health record is an allowed source**, though two are allowed *targets*. |
| **Proven, not inferred** | enumerating every relationship type: edges permitting `capability-health-state` → `capability-health-observation`: **NONE**. `capability-degradation-event` → `capability-health-observation`: **NONE**. `capability-health-recommendation` → `capability-health-state`: **NONE**. The four Health relationships cover subject (`OBSERVES_HEALTH_OF`, `HEALTH_STATE_OF`, `RECOMMENDS_ACTION`) and envelope (`EVALUATED_AGAINST`) and none of them covers evidence. |
| **Why it matters** | the citation chain is what makes determinism *auditable* rather than merely claimed. It exists as a field on three schemas and as a governed relationship nowhere, so the ontology cannot validate the one chain ADR-0013's audit section rests on. |
| **Why implementation cannot guess** | adding an edge type to the relationship catalog is a governance change, and the choice between widening `DERIVED_FROM` and adding a dedicated edge determines whether the forbidden trust pairings keep covering health evidence. |
| **Smallest resolution** | add `capability-health-state`, `capability-degradation-event` and `capability-health-recommendation` to `DERIVED_FROM.allowed_sources`, and `capability-health-observation`/`capability-health-state` are already permitted targets. The existing `forbidden_source_target_pairs` continue to bar trust from deriving from health, which is the pairing that must never exist. |
| **ADR_CHANGE_REQUIRED** | **NO** — ADR-0013 already states the requirement; the catalog omits the means. |

### GAP-3 — No condition grammar, so deterministic evaluation cannot be built

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Requires** | ADR-0013: "A health state is a **deterministic function** of its cited observations and the envelope… Identical inputs produce an identical state, every time." `degradation-semantics.md`: "A transition an operator cannot reproduce from the cited evidence is one they cannot argue with, which makes it useless during a review." |
| **Declared** | `entry_condition` and `exit_condition` are **required** on every envelope dimension. Neither has a declared type, grammar, operator set, or evaluation semantics. |
| **Only exemplars** | `worked-examples.md:102-103` — `entry_condition: "p95 > 2000ms"` and `"> 32"`. Free text, two different shapes, one of them carrying a unit inside the string. |
| **Second-order hole** | `"p95 > 2000ms"` requires **percentile aggregation over a window**. CHOBS is defined as "one measurement, of one dimension, of one subject, at one **moment**", and `sample_window_seconds` is **optional**. So the exemplar condition cannot be evaluated against the record the architecture defines as its input, and nothing says which observations form the window, how they are selected, or what happens when the window is partially collected. |
| **Why implementation cannot safely guess** | choosing a grammar **chooses the policy surface**. A parser that accepts `p95` commits the platform to percentile semantics nobody declared; one that rejects it makes the architecture's own worked example invalid. Either way an implementer would be authoring threshold semantics, and "thresholds are human-declared" is principle 7. |
| **Smallest resolution to consider** | a new ADR declaring a minimal closed condition grammar — a comparison operator from a closed set, a numeric bound, a declared unit matching the dimension's `unit`, and an explicit aggregation (`instant`, or a named aggregation with a required window) — with the worked examples restated in it. Closed rather than expressive, for the same reason the recommendation vocabulary is closed. |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** |

### GAP-4 — No hysteresis grammar, so CHDEG cannot be deterministic

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Requires** | ADR-0013: "**Hysteresis is required**, not optional." `degradation-semantics.md`: "A transition that cannot show its hysteresis was satisfied is **not recordable**." |
| **Declared** | `hysteresis` is a required dimension field. `operational-envelope.md:23` defines it as "**How long or how often** the condition must hold". |
| **The hole** | "how long" and "how often" are two different semantics with no discriminator, no type, and no declared representation. CHDEG's only hysteresis field is the **optional** `hysteresis_satisfied_over_seconds` — a duration — so the "how often" half has nowhere to be recorded even when it is the declared condition. A transition satisfied by occurrence count could not "show its hysteresis was satisfied", and by the architecture's own rule would therefore not be recordable. |
| **Why implementation cannot guess** | the two readings produce different transitions from identical observations, which is precisely the non-determinism the architecture forbids. |
| **Smallest resolution** | fold into GAP-3's grammar ADR: a discriminated hysteresis — `{kind: duration, seconds: n}` or `{kind: occurrences, count: n, within_seconds: n}` — and a matching required evidence field on CHDEG for whichever kind applied. |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** |

### GAP-5 — No evaluation trigger

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **The hole** | nothing specifies **when** a CHSTATE is derived — on observation write, on read, on a schedule, or on demand. ADR-0013 excludes "no evaluation loop" from *its* release, which is correct for an architecture-only release and leaves ENG-0006 with the decision. |
| **Why it is architectural, not a detail** | the trigger decides whether `freshness` is computed at write time or read time, and therefore whether a **stored** state can be stale by construction. A read-time derivation makes states ephemeral and cannot satisfy `append_only_history: true`; a write-time derivation needs a clock and a scheduler, and a state written once is stale the moment its evidence ages — meaning the stored `freshness` value is a claim about the past that re-reading cannot correct without writing a new record. |
| **Smallest resolution to consider** | declare derivation as **explicitly invoked and append-only**: every evaluation writes a new CHSTATE carrying its own `evaluated_at`, and a reader computes current freshness from `evaluated_at` plus the per-dimension policy rather than trusting the stored label. No daemon in the first implementation. |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** |

### GAP-6 — `withheld` has no creation authority

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **The hole** | no document or schema says **who or what sets `withheld`**. The only related statement is permissive: `availability_intent` "**may** influence whether Health evaluates or publishes", and the schema's `availability_intent_may_influence_publication: true`. "May influence" is not a derivation rule. |
| **Why implementation cannot guess** | `withheld` is the one health state that is explicitly **not a finding derived from evidence**, so the deterministic evaluator cannot produce it from observations and the envelope. Something else must author it, and nothing says what. Deriving it from `availability_intent` is the resolution CONFLICT-3 exists to forbid. |
| **Smallest resolution to consider** | an explicit, human-authored withholding declaration with its own authority and an immutable supersession — or, smaller, a declared rule that `withheld` is authored only by a named operator action and never derived. Either way it needs an author, and adding a seventh record family is the thing this gate is instructed not to do unilaterally. **Flagged as the one place a new persistent record family might be required; not adopted.** |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** |

### GAP-7 — No replay, idempotency, or receipt-time rule for heartbeats

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Requires** | ADR-0013: a heartbeat "is a **claim** and never a grant". `observation-model.md`: "A subject saying it is alive is evidence that **something sent a message**, which is not the same as the capability working." |
| **Declared** | CHBEAT requires `heartbeat_id`, `subject_type`, `subject_id`, `observed_at`, `provenance`. `sequence` is **optional**, with no stated monotonicity, uniqueness, or dedupe rule. Searching all Health documents and schemas for `replay`, `idempot`, `nonce` or `monotonic` returns **one hit**: the optional `sequence` field itself. |
| **The hole** | `observed_at` is not distinguished from received-at. A subject therefore controls the timestamp that drives the `heartbeat-freshness` dimension, and a **replayed heartbeat is schema-valid** — it refreshes liveness for a subject that has stopped. This is the self-reporting attack ADR-0013 names in its Context ("a node that wants work need only look healthy") with no mechanism against it. |
| **Why implementation cannot guess** | a receipt timestamp, a monotonic sequence requirement and a dedupe window are each a different trust model for a self-reported claim, and picking one silently decides how much a claim is worth. |
| **Smallest resolution** | require a Health-authored `received_at` distinct from the subject's `observed_at`, compute `heartbeat-freshness` **only** from `received_at`, and make `sequence` required and strictly increasing per subject with replays recorded as refused rather than ignored. |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** |

### GAP-8 — No declared store root, and the choice is architecturally load-bearing

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Released peers** | Fabric `/var/lib/kyri/fabric` · Capability Runtime `/data/kyri/capability-runtime` · Trust `/var/lib/kyri/trust`. Health has **no declared location anywhere** in ADR-0013, `docs/health/`, or the six schemas. |
| **Why it is not a mere detail** | if health records lived inside the Fabric store, the Health writer would hold **write access to the Fabric store**. Invariant 16 — "Health cannot mutate Trust or Fabric state" — would then rest on application-level discipline rather than on filesystem authority, which is the weaker of the two and the one that fails under a bug. |
| **Smallest resolution** | a separate immutable store root owned by Health, with the Fabric reachable only through a read-only adapter (§F). |
| **ADR_CHANGE_REQUIRED** | **NO** — a deployment and boundary decision, consistent with every existing plane. |

### GAP-9 — An observation's `source` is unconstrained and unauthenticated

| | |
|---|---|
| **Classification** | SPECIFICATION_GAP |
| **Declared** | `source` is required on CHOBS — "The named source that produced it. A measurement with no source cannot be weighed against a contradicting one." |
| **The hole** | free text. No `source_type`, no trust subject, no authentication, no integrity binding. A forged CHOBS naming any source is schema-valid. And the rationale promises weighing — "cannot be weighed against a contradicting one" — while **no rule for weighing two contradicting sources is defined anywhere**, so the field's stated purpose is unmet even when it is populated honestly. |
| **Why implementation cannot guess** | a conflict-resolution rule between sources is policy. Picking one (newest wins, most-trusted wins, disagreement yields `unknown`) decides what an attacker with one compromised collector can achieve. |
| **Smallest resolution to consider** | constrain `source` to a declared collector identity from a closed registry, and declare that contradicting fresh observations of the same dimension from different sources yield `unknown` with both cited — fail-closed on the claim, inert on eligibility, which is the architecture's own rule applied to its own disagreements. |
| **ADR_CHANGE_REQUIRED** | **REVIEW_REQUIRED** |

### GAP-10 — CHSTATE omits `review_required`, which the inherited Null Policy Rule requires

| | |
|---|---|
| **Classification** | IMPLEMENTATION_DETAIL_MISSING |
| **Requires** | `observation-model.md`: "The **Null Policy Rule** is **inherited exactly**." The Confidence and Freshness Standard's conformance list: "a null freshness policy produces `unknown` **with `review_required: true`**, never a default maximum age." |
| **Released surface** | CHSTATE's `required_fields` carry `freshness` and `reason` but **not** `review_required`. Of the six Health schemas only CHREC carries it. |
| **Why it matters** | "inherited exactly" is falsified by omission. A CHSTATE of `unknown` arising from a null policy is schema-valid without the flag the standard makes mandatory, so the pressure-to-define-the-policy the rule exists to create does not reach the record. |
| **Smallest resolution** | add `review_required` to CHSTATE, required when `freshness: unknown` arises from a null policy. |
| **ADR_CHANGE_REQUIRED** | **NO** |

---

## E. The four-stage boundary: observation → state → degradation → recommendation

Derived from the accepted architecture, not invented here.

| Stage | Record | Authority | May conclude? | Determinism |
|---|---|---|---|---|
| **Measure** | CHOBS, CHBEAT | a named collector (CHOBS); the subject itself (CHBEAT) | **No.** `forbidden_fields` bar `health_state`, `verdict`, `conclusion`, `assessment` | n/a — a measurement |
| **Derive** | CHSTATE | the Health evaluator, never a collector and never the subject | **Yes**, and only this stage | **Required.** Pure function of cited CHOBS + envelope version |
| **Transition** | CHDEG | the same evaluator, on a state change | describes **observed history only** | **Required**, and gated on declared hysteresis |
| **Advise** | CHREC | the same evaluator | advice only — `advisory_only: true`, `requires_human_action: true`, `auto_execution: forbidden` | not required; a human reads it |

**The boundaries that must hold in code, each traceable to a declared field:**

- **A collector may never write a CHSTATE.** The derivation stage is the only one
  permitted to conclude, and an observation that concluded "would be a
  measurement that had already decided".
- **A subject may never write anything but its own CHBEAT**, which confers
  nothing: `confers_trust: false`, `confers_eligibility: false`.
- **CHDEG follows CHSTATE, never observations directly.** It is a transition
  *between states*, so a degradation event with no prior state is not
  constructible.
- **CHREC follows CHSTATE** via its required `derived_from_state_id`, optionally a
  CHDEG. A recommendation that cited nothing would be an opinion.
- **Nothing downstream of CHREC exists.** The layer's authority ends at a record
  asking a person to look.

**One naming observation, not a gap:** the relationship type is
`RECOMMENDS_ACTION` ("Recommends Action") for a record whose entire contract is
that it is **not** an action. Its description is correct. Worth a reviewer's
glance; it is cosmetic and I have not changed it.

**One transition-semantics question for the reviewer.** `health-states.md` says
"**Every** transition between health states produces a degradation event,
including recovery", and CHDEG's `from_state`/`to_state` enums admit all seven
states. Taken literally, `unknown → unmonitored` and `unknown → healthy` both
produce a *degradation* event, which is a record type named for something that
did not happen. The architecture is consistent — it wants every transition
recorded — but the record's name fights its enum. Whether the first observation
of a subject is a "transition" at all is undefined, and a naive implementation
would emit a degradation event the first time it ever evaluated anything.

---

## F. Fabric integration without Health becoming a Fabric mutator

**FABRIC_INTEGRATION_DEFINED = YES**, structurally — the released hook exists and
its shape is right. The *evidence* that may use it is blocked on GAP-3 and GAP-4,
and its *disclosure* on GAP-1.

**Where the Health read occurs.** Not inside the Fabric. The released
`select_candidate(..., health_removals=())` takes an **opaque set of
`capability-instance` identifiers** from its caller, validates each as an
instance identifier, folds the set into the request digest, and applies it as the
exclusion reason `candidate-removed-by-health-input` **after**
`evaluate_eligibility` has run. The Fabric reads no health record and must not
start: a Fabric that read health records would be reimplementing health
evaluation, which is the argument `trust_adapter.py` already makes about trust —
"two implementations of 'is this subject trusted' is one too many".

**The precedent to copy.** `tools/fabric/trust_adapter.py` is the exact pattern a
`health_adapter` should follow, and its docstring is effectively the
specification: it "asks a question and reports the answer", "owns no verdict of
its own", "**fails closed, always**" with absent, expired, revoked, malformed,
unreadable and unavailable all resolving to one answer, "remembers nothing and
asks once", takes the evaluation instant **from the caller** because "an adapter
that read the time would answer a question nobody asked", and draws refusals from
a controlled vocabulary so no path or exception detail can reach a record.

**Note the privilege direction.** The adapter must be read-only over the Health
store, and the Fabric must hold no write path to it — the mirror of GAP-8.

**What exactly may subtract a candidate.** Only a CHSTATE that is **fresh** and
**positively** `degraded` or `unavailable`, evaluated against a named envelope
version. Four conditions, all required: the state is one of those two; its
freshness is `current`; the evidence it cites is itself within its declared
per-dimension policy; and the subject identity matches the candidate exactly.

**Per-state behaviour, each traceable to a declared field:**

| Health input | Effect on eligibility | Declared by |
|---|---|---|
| `unknown` | **inert** — removes nothing, adds nothing | `unknown_effect_on_eligibility: inert` |
| `unmonitored` | **inert** | `inert_states` |
| `insufficient-policy` | **inert** | `inert_states` |
| stale evidence, any state | **inert** — cited with its age, carries no current claim | `removal_requires: fresh-positive-evidence`, `stale_may_support_healthy: false` |
| `collection_status: failed` / `unavailable` | **inert** — a collection failure concludes nothing about the subject | `collection_failure_implies_subject_failure: false` |
| `degraded`, fresh | **may remove** | `health-states.md`: "May remove, **per route policy**, on fresh evidence" |
| `unavailable`, fresh | **removes** | `health-states.md`: "**Removes**, on fresh evidence" |
| `withheld` | **inert** | `withheld_semantics.removes_eligibility: false` |
| `healthy`, however fresh | **nothing** — health never adds | `may_add_to_eligibility: false` |
| **malformed Health record** | **inert, and refused loudly** | §I |

**A gap inside this table, flagged rather than resolved.** `degraded` removes
"**per route policy**", and **no route policy field for health exists**. The
released `capability-route` schema declares no health policy, and `select_candidate`
applies `health_removals` uniformly with no per-route modulation. So the
difference `health-states.md` draws between `degraded` (conditional on route
policy) and `unavailable` (unconditional) **cannot be expressed**. The
caller-supplied `health_removals` set collapses both into one opaque decision
made outside the Fabric. Classification: **SPECIFICATION_GAP**, folded into GAP-1
for resolution because both concern what the Fabric records and honours about
health. `ADR_CHANGE_REQUIRED=REVIEW_REQUIRED`.

**How freshness is established.** Per observation, independently per dimension —
`unknown-and-freshness.md`: "a subject may hold current latency evidence and
stale availability evidence at once. Collapsing them to a single age would hide
whichever dimension stopped reporting." A single subject-level age is therefore
forbidden, and the adapter must carry per-dimension freshness or the removal
cannot be justified.

**Fail-closed on malformed health records — and note which way "closed" points.**
Everywhere else in this platform fail-closed means *refuse*. Here it means
**refuse the health claim**, which leaves the candidate eligible, because health
only ever subtracts. A malformed health record must therefore: produce no
removal; never be read as `healthy`; surface as a refusal in a controlled
vocabulary; and be conspicuous in the selection explanation. Treating malformed
health as removal would hand an attacker a denial-of-service through the
observability layer — corrupt the health store, empty every route — which is the
`unknown`-removes-candidates failure arriving by a different door.

---

## G. Capability Runtime reconciliation — is CRES a Health observation source?

**CAPABILITY_INTEGRATION_DEFINED = YES.**

**Answer: CRES/result history is an input to a collector.** Not a Health
observation in its own right, and not outside Health. Four reasons from the
accepted architecture:

1. **The Capability Runtime cannot push.** It is "architecturally barred from the
   health and orchestration plane — liveness, heartbeat, scheduling"
   (`tools/capability/execution/recovery.py`), and
   `tests/test-capability-runtime.sh:143-145` enforces it **by name**, forbidding
   `tools.health`, `..health`, `liveness`, `readiness`, `heartbeat`.
   `quarantine.py` adds that quarantined output "cannot reach Fabric, Trust, or
   Health". The only permitted direction is **Health reads Capability**.
2. **CHOBS is collector-shaped.** It requires a named `source` and a
   `collection_status` from `{collected, failed, unavailable}`. Those are
   collector concepts. A CRES promoted directly to an observation would have no
   honest `collection_status`, and a direct CRES→CHSTATE derivation would **skip
   the collection-failure distinction entirely** — the one rule ADR-0013 says
   "matters more here than anywhere".
3. **ADR-0013 already names the dimension.** Line 315 lists "execution outcomes"
   among the signals that "stay individually explainable", alongside latency and
   heartbeat.
4. **The data supports it.** Production `CRES-000002` carries `outcome_class:
   completed`, `started_at`, `ended_at`, `attempt_number` and
   `invocation_record_id`. Latency is derivable from the instants; success and
   failure counts from `outcome_class` over a declared window.

**Gap inside this answer.** CHOBS's `dimension` enum has `success-count` and
`failure-count` but **no dimension for execution outcome class**, and no document
declares the mapping from the Capability Runtime's outcome vocabulary — which
includes `completed`, `refused`, `provider-error`, `adapter-error`, `interrupted`,
`cancelled` — onto those two counters. Whether `refused` is a failure is a policy
question with an operational answer: a governed refusal is the runtime working
correctly, and counting it as a failure would make correct fail-closed behaviour
look like degradation. **Classification: SPECIFICATION_GAP**, folded into the
collector increment and listed in the summary count.
`ADR_CHANGE_REQUIRED=REVIEW_REQUIRED`.

---

## H. Heartbeat claim versus independently observed liveness

**They are different records and must not be conflated. The architecture says so
and provides no mechanism to enforce it — GAP-7.**

| | `capability-heartbeat` (CHBEAT) | `availability` observation (CHOBS) |
|---|---|---|
| **Author** | the subject, about itself | a named collector, about the subject |
| **Class** | `record_class: claim` | `record_class: evidence` |
| **Confers** | nothing — `confers_trust: false`, `confers_eligibility: false` | nothing either, but it is independent |
| **Absent means** | `absent_heartbeat_means: unknown-never-healthy` | `unknown`, and not proof of failure |
| **May support `healthy`?** | **Only as one dimension among several** | Same |

**The rule that must survive implementation:** a self-reported heartbeat becomes
a *measured* input only through `heartbeat-freshness`, which is one dimension of
several and never the definition of health. ADR-0013: "That is why heartbeat
freshness is one dimension among several rather than the definition of health."
A subject that only heartbeats and is measured on nothing else must not reach
`healthy` on the strength of its own claims — and with `evaluation:
worst-dimension-wins` plus `absent_threshold_means: insufficient-policy`, the
envelope mechanism already produces that outcome, provided the envelope declares
more than one dimension. **An envelope declaring heartbeat-freshness alone would
let a subject certify its own health**, which is worth an explicit test rather
than a hope.

**And the hole:** nothing distinguishes the subject's `observed_at` from a
Health-authored receipt time, so the subject controls the clock that drives the
one dimension derived from its own claim. GAP-7.

---

## I. Security and trust-boundary risks

| Risk | Status | Mechanism, or the gap |
|---|---|---|
| **Health used to grant eligibility** | **Closed** | `may_add_to_eligibility: false`; health is not among the twelve `ELIG` conditions; `select_candidate` has no additive path |
| **Health mutating Trust** | **Closed** | `may_modify_trust_state: false` on all six schemas; `DERIVED_FROM.forbidden_source_target_pairs` bars trust-record and trust-decision from citing health |
| **Health becoming an autonomous control plane** | **Closed by vocabulary** | CHREC's closed four-value enum plus forbidden fields — `command`, `argv`, `script`, `shell`, `execution_target`, `action_payload`, `auto_execute`, `auto_apply`, `auto_drain`, `auto_quarantine`, `execute_at`, `route_id`, `selection_id`, `mutates_route`, `mutates_trust_state` — named as forbidden rather than merely omitted, so a future field cannot reintroduce one and still pass |
| **Monitoring outage causing platform outage** | **Closed by design** | `unknown_effect_on_eligibility: inert`. ADR-0013 accepts the cost explicitly: "a truly broken but unmonitored capability may remain eligible" |
| **Health overriding quarantine** | **Closed** | quarantine is `ELIG-10`, evaluated independently of and before any health subtraction; `cannot_override` lists quarantine |
| **Malicious self-reporting** | **Partly open** | CHBEAT confers nothing and heartbeat-freshness is one dimension — but a single-dimension envelope would let a subject certify itself (§H) |
| **Replayed / stale observations** | **OPEN — GAP-7** | no replay rule, no monotonic sequence requirement, no receipt time distinct from the claimed instant |
| **Forged good-health observations** | **OPEN — GAP-9** | `source` is unauthenticated free text; a forged CHOBS naming any source is schema-valid |
| **Collector compromise** | **OPEN — GAP-9** | no conflict-resolution rule between contradicting sources, though the field's rationale promises weighing |
| **Threshold manipulation** | **Mostly closed, one hole** | `authored_by: human`, `threshold_source: declared-only`, `baseline_promotion: forbidden`, `violation_widens_threshold: false`, `change_requires: immutable-approval`. The hole is GAP-3: with no declared grammar, a condition string is whatever a parser decides it means |
| **Subject / reference substitution** | **Partly open** | `subject_type` and `subject_id` are required everywhere and `OBSERVES_HEALTH_OF` constrains targets to instance/host/package — but **no rule requires a CHSTATE's subject to match the subject of every observation it cites.** A state could cite another subject's observations and remain schema-valid. Folded into the validation increment as a required assertion; listed in the gap count |
| **Denial of service via corrupted health store** | **Closed if §F is honoured** | malformed health must be inert, never a removal. If an implementation treated malformed health as grounds for removal, corrupting the store would empty every route |
| **Health data leaking into Trust by inference** | **Closed** | the forbidden pairings are declared per-pair precisely because the flat source/target lists cannot express it |

---

## J. Reconciliation summary

| # | Finding | Classification | ADR change |
|---|---|---|---|
| C1 | Six vs seven health states | SPECIFICATION_CONFLICT | **YES** |
| C2 | Two vs four recommendation kinds; `drain` is not a valid value | SPECIFICATION_CONFLICT | **YES** |
| C3 | `withheld` table row restates the repudiated draft | SPECIFICATION_CONFLICT | **YES** |
| G1 | Selection visibility unimplementable on the released CSEL record | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G2 | Evidence citation chain has no relationship edge | SPECIFICATION_GAP | NO |
| G3 | No condition grammar; determinism unachievable | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G4 | No hysteresis grammar; CHDEG not deterministic | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G5 | No evaluation trigger | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G6 | `withheld` has no creation authority | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G7 | No heartbeat replay / receipt-time rule | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G8 | No declared store root | SPECIFICATION_GAP | NO |
| G9 | Observation `source` unauthenticated; no weighing rule | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G10 | CHSTATE omits `review_required` | IMPLEMENTATION_DETAIL_MISSING | NO |
| G11 | No route-level health policy for the `degraded` case | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G12 | No CRES outcome-class → dimension mapping | SPECIFICATION_GAP | REVIEW_REQUIRED |
| G13 | No rule binding a CHSTATE's subject to its cited observations' subject | SPECIFICATION_GAP | NO |
| — | Twelve architectural claims verified against released surfaces (§A) | CONSISTENT | — |
| — | `endpoint-health`, `lease-health`, `placement-health` reconciled away | SUPERSEDED_BY_ACCEPTED_ARCHITECTURE | — |

**No finding is SUPERSEDED_BY_ACCEPTED_ARCHITECTURE except the three reserved
entity names**, which ADR-0013 itself reconciled and the roadmap records.

**No new persistent record family is adopted.** GAP-6 (`withheld` authority) is
the one place where a demonstrable hole might require one; it is raised as a
proposal and stops here, per the gate's instruction.

---

## K. Test strategy, before implementation

Test-first, and **every assertion must name the surface it reads**. The §36 audit
and ENG-0005's F4 finding both turned on tests that proved prose rather than
behaviour, and `tests/test-capability-health.sh` currently demonstrates the
failure mode directly: it asserts seven states from the schema and never compares
the schema to the ADR, which is why CONFLICT-1 survived a green suite.

**Cross-artefact agreement — the class of test that is missing today.** Assert
that ADR-0013's state table, `health-states.md`'s table, and the CHSTATE and
CHDEG enums declare the **same set**, by extracting all four and comparing. Same
for the recommendation vocabulary across ADR-0013, `governance-boundaries.md` and
the CHREC enum. These three tests alone would have caught all three conflicts.

**Inertness and absence.** `unknown` removes nothing and adds nothing ·
`unmonitored` inert · `insufficient-policy` inert · `withheld` inert · stale
evidence of any state inert · `collection_status: failed` and `unavailable`
conclude nothing · no absence renders as `assumed-healthy`,
`probably-available`, `no-known-issues` or `healthy-by-default` · every state
including `unknown` carries freshness and a written reason · the freshness of
nothing is `unknown`, never `stale`.

**Subtraction, and only as specified.** `healthy` grants nothing however fresh ·
fresh `degraded` subtracts only as the resolved route policy permits (G11) ·
fresh `unavailable` subtracts · a stale `degraded` never becomes `healthy` and
never subtracts · `unknown` never clears a prior finding — silence is not
recovery · health never reorders candidates.

**Precedence.** Quarantine wins over any health state · `availability_intent`
wins · restricted scope wins · revocation wins · manual drain wins and a fresh
`healthy` does not reverse it · `withheld` remains distinct from
`availability_intent` in both directions, including the divergent cases.

**Fail-safe.** A malformed CHENV, CHOBS, CHSTATE, CHDEG or CHREC produces **no
removal**, is never read as `healthy`, and refuses in a controlled vocabulary
carrying no path, value or exception detail · an unreadable health store leaves
every candidate eligible · a corrupted health store cannot empty a route ·
subject mismatch between a state and its cited observations is **rejected** (G13)
· a reference to a non-existent CHOBS, CHENV or CHSTATE is rejected.

**Determinism.** Identical observations and envelope version produce an identical
CHSTATE, asserted by repeated derivation · identical inputs produce an identical
CHDEG · one observation under two envelope versions yields two states and
**neither rewrites the other** (the `worked-examples.md` example 7 case, as an
executable test) · hysteresis unsatisfied produces **no** transition · hysteresis
satisfied produces exactly one · a transition that cannot evidence its hysteresis
is not recordable.

**Immutability and replay.** Every family is append-only · supersession writes a
new record and never edits · an envelope supersession does not alter prior
CHSTATEs · a replayed CHBEAT is refused rather than silently refreshing liveness
(G7) · re-derivation is idempotent in effect and append-only in record.

**Negative surface — assert absence, by name.** No `health_score`,
`aggregate_score`, `composite_score`, `weighted_health`, `overall_numeric_health`
or any cross-dimension numeric ranking · no `predicted_*`, `forecast`,
`time_to_failure`, `probability` or `anomaly_score` · no `learned_threshold`,
`auto_threshold`, `baseline_threshold` or `derived_threshold` · no `command`,
`argv`, `script`, `shell`, `execution_target`, `action_payload`, `auto_execute`,
`auto_apply`, `auto_drain`, `auto_quarantine` or `execute_at` · no write path
from Health to the Trust store · no write path from Health to the Fabric store ·
no import of a Trust or Fabric *mutator* anywhere in the Health package, asserted
by module name the way `tests/test-capability-runtime.sh` already asserts the
reverse direction.

**The self-certification test §H argues for.** An envelope declaring only
`heartbeat-freshness` must not let a subject reach `healthy` on its own claims.

---

## L. Proposed implementation decomposition

**PROPOSED_IMPLEMENTATION_INCREMENTS = 21**, in six phases. Optimised for
authority boundaries and reviewability, not for count. Phase 0 is reviewer work
and blocks everything after it: nothing in Phase 1+ may begin while the grammar
and the state set are undecided, because every later increment would encode a
guess.

**Phase 0 — architecture resolution (reviewer-gated, no code)**

| # | Increment | Resolves |
|---|---|---|
| 0.1 | ADR-0013 corrections: state table, recommendation vocabulary, `withheld` row | C1, C2, C3 |
| 0.2 | Relationship catalog: health records as `DERIVED_FROM` sources | G2 |
| 0.3 | **New ADR: condition and hysteresis grammar**, closed, with aggregation and windowing | G3, G4 |
| 0.4 | **New ADR or ADR-0012 amendment: selection health disclosure**, forward-only, plus route-level health policy | G1, G11 |
| 0.5 | Decision: evaluation trigger, store root, `withheld` authority | G5, G6, G8 |
| 0.6 | Decision: collector identity, source weighing, heartbeat replay and receipt time | G7, G9 |
| 0.7 | Schema corrections: CHSTATE `review_required`, CHREC header prose, subject-binding rule | G10, G13 |

**Phase 1 — foundation (no evaluation, no conclusions)**

| # | Increment |
|---|---|
| 1.1 | Health immutable store: six record directories, six sequences, ownership and mode enforcement, reusing the released `ImmutableStore` contract |
| 1.2 | Identifier allocation and widths — `CHENV` 4-digit, five families 6-digit, refusing rollover |
| 1.3 | Record models and fail-closed validation for all six families, including forbidden-field rejection |

**Phase 2 — evidence intake (still no conclusions)**

| # | Increment |
|---|---|
| 2.1 | CHENV authoring, versioning and supersession, with immutable approval |
| 2.2 | CHOBS write path, with `collection_status` and null `measured_value` on failure |
| 2.3 | CHBEAT intake with the resolved replay and receipt-time rule |
| 2.4 | Per-dimension freshness computation, Null Policy Rule inherited exactly |

**Phase 3 — derivation (the only stage permitted to conclude)**

| # | Increment |
|---|---|
| 3.1 | Condition evaluator — pure, total, deterministic, against the Phase 0.3 grammar |
| 3.2 | CHSTATE derivation: `worst-dimension-wins`, envelope version cited, subject binding enforced |
| 3.3 | CHDEG transitions with hysteresis gating |
| 3.4 | CHREC emission from the closed four-value vocabulary |

**Phase 4 — integration (read-only, in this order)**

| # | Increment |
|---|---|
| 4.1 | `health_adapter` — the `trust_adapter` pattern: fails closed, owns no verdict, remembers nothing, instant from the caller, controlled refusal vocabulary |
| 4.2 | Selection health disclosure per the Phase 0.4 resolution, forward-only |
| 4.3 | Wiring `health_removals` to the adapter, with malformed health inert |
| 4.4 | Capability-result collector: CRES → CHOBS, with the resolved outcome-class mapping |

**Phase 5 — governance and surface**

| # | Increment |
|---|---|
| 5.1 | Negative-surface suite: no score, no prediction, no remediation, no Trust or Fabric write path |
| 5.2 | Cross-artefact agreement suite — ADR, docs and schemas assert the same sets |
| 5.3 | Health CLI, read paths first |

**Why `health_adapter` precedes selection disclosure.** The adapter is the only
thing that may answer "what does health say about this candidate", and building
the disclosure first would mean writing the answer's shape before its source
exists — which is how a selection record ends up carrying a field no adapter can
populate honestly.

---

## M. Proposed ENG-0006 runtime design specification

**Warranted, and not written here.** A specification would have to choose a
condition grammar, an evaluation trigger, a store root, a `withheld` authority
and a heartbeat trust model — the five decisions this gate is instructed to stop
in front of. Writing it now would bury five unresolved architecture decisions
inside a document that reads as settled.

Proposed path, following the ENG-0004 and ENG-0005 convention:

```
docs/superpowers/specs/<date>-health-runtime-design.md
docs/superpowers/plans/<date>-eng-0006-health-runtime-implementation-plan.md
```

Proposed outline: subject identity and store model · the six families, each with
the ten properties in §N · the four-stage authority boundary · the condition and
hysteresis grammar (from Phase 0.3) · derivation and determinism · the Fabric
read boundary and the adapter contract · the Capability collector boundary ·
freshness and the Null Policy Rule · security boundaries and the threat table
from §I · the test matrix from §K.

**It should be written after Phase 0, not before.**

---

## N. Per-family properties (question C)

Common to all six: immutable · `update_methods: none` · `delete_methods: none` ·
`supersession: new-record-only` · `may_modify_trust_state: false` ·
`may_execute: false` · `provenance` required. Store location is **undeclared** for
all six (GAP-8). Allocation would follow the released flock'd `.seq` pattern.

| | CHENV | CHBEAT | CHOBS | CHSTATE | CHDEG | CHREC |
|---|---|---|---|---|---|---|
| **Subject identity** | instance / host / package | instance / host | instance / host / package | instance / host / package | instance / host / package | instance / host / package |
| **Identifier** | `CHENV-[0-9]{4}` | `CHBEAT-[0-9]{6}` | `CHOBS-[0-9]{6}` | `CHSTATE-[0-9]{6}` | `CHDEG-[0-9]{6}` | `CHREC-[0-9]{6}` |
| **Creation authority** | **human**, with immutable approval | **the subject** (a claim) | **collector** | **deterministic derivation** | **deterministic derivation** | **deterministic derivation** |
| **Validation authority** | Health | Health | Health | Health | Health | Health |
| **References** | subject only | subject only | subject | subject, CHENV + version, CHOBS ids | subject, CHOBS ids, CHENV optional | subject, CHSTATE, CHDEG optional |
| **Supersession** | versioned, never reaches back | n/a — append-only | n/a — append-only | superseded, never edited | n/a — a historical event | n/a — advice stands |
| **Freshness** | declares the policy, null permitted | drives `heartbeat-freshness` | carries its own | **required on every state** | inherited from cited evidence | inherited from the state |
| **Replay / idempotency** | re-approval is a new version | **UNDEFINED — GAP-7** | undefined; dedupe unspecified | re-derivation appends | one event per transition | one per evaluation |
| **Malformed reference** | — | — | — | must **refuse**; never partial | must refuse | must refuse |
| **Who creates** | human | subject | collector | derivation | derivation | derivation |

`CHBEAT` omits `capability-package` from its `subject_type` enum, correctly — a
package is not a running thing and has no liveness. `CHOBS` admits package for
**all** dimensions including `availability`, which is harder to justify; worth a
reviewer's glance, not raised as a gap.

---

## O. What was not done

No runtime code. No provisioning. No production record. No Fabric, Capability,
Trust or Health store was written or read for mutation — the production reads in
this report are the five `capability-selection` records and `CRES-000002`, read
only to establish what the released records actually contain. ENG-0005's branch,
reports, records and tag are untouched. No conflict or gap was resolved. No ADR
was edited. No schema was changed. No seventh record family was adopted. No
ENG-0006 specification was written. ENG-0003 and ENG-0007 were not entered.

---

## P. Result

```
RESULT=REVIEW_REQUIRED
BASELINE_HEAD=5c7ff9abed3dce628218b78ad9d4610d886023d8
BRANCH=arch/eng-0006-health-runtime
ADR0013_STATUS=CONFLICTS_FOUND
HEALTH_SCHEMAS_FOUND=6
RECORD_FAMILIES=CHENV,CHBEAT,CHOBS,CHSTATE,CHDEG,CHREC
SPECIFICATION_GAPS=13
SPECIFICATION_CONFLICTS=3
ADR_CHANGE_REQUIRED=YES
FABRIC_INTEGRATION_DEFINED=YES
CAPABILITY_INTEGRATION_DEFINED=YES
PROPOSED_IMPLEMENTATION_INCREMENTS=21
RUNTIME_CODE_CHANGED=NO
PRODUCTION_FABRIC_MUTATION=NONE
PRODUCTION_CAPABILITY_MUTATION=NONE
PRODUCTION_TRUST_MUTATION=NONE
PRODUCTION_HEALTH_MUTATION=NONE
NEXT=reviewer evaluates reconciliation and authorizes architecture corrections or ENG-0006 implementation plan
```

**`ADR_CHANGE_REQUIRED=YES`** because CONFLICT-1, CONFLICT-2 and CONFLICT-3 each
require an edit to ADR-0013 itself. Eight further findings are marked
`REVIEW_REQUIRED` individually in §J; whether each lands in ADR-0013, in a new
ADR, or in ADR-0012 is the reviewer's decision.

**`SPECIFICATION_GAPS=13`** counts G1–G13. The brief's template anticipated a
single figure; G11, G12 and G13 were found inside questions E, F and I rather
than in the gap sweep, and they are counted rather than left out of the total.

## Related

- [ADR-0013: The Capability Health Plane](../../../decisions/ADR-0013-capability-health-plane.md)
- [Capability Health overview](../../../health/capability-health.md)
- [ENG-0005 G7 re-entry](../eng-0005/2026-10-12-g11-bc-ay-g7-re-entry.md)
- [Engineering ledger](../../../history/v1.0-engineering-ledger.md)
