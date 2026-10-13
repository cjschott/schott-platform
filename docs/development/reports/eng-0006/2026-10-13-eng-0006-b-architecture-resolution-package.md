# ENG-0006-B — Health architecture resolution package

**Date:** 2026-10-13 · **Branch:** `arch/eng-0006-health-runtime`
**ENG-0006-A checkpoint:** `719ec60ed9d5f6d7d507c3a9cd0aa2485b269cbb` — ACCEPTED
**Released prerequisite:** `v0.11.0` → `ce0debb8be3c87babf6856fb7f694c590fc667a1`

**RESULT: REVIEW_REQUIRED.** Architecture and specification gate. Health Runtime
implementation is **NOT AUTHORIZED** and none was written.

**NORMATIVE_DECISIONS_APPLIED = 0.** No ADR, schema, ontology or runtime file was
edited. The only change applied in this increment is the ENG-0006-A bookkeeping
correction the reviewer asked for, recorded in §0.

This package turns the sixteen ENG-0006-A findings — C1–C3 and G1–G13 — into
decision-ready proposals. Each is a separate record with the required eighteen
fields, every reviewer decision is **PENDING**, and no unresolved choice is
buried in prose: where more than one option is defensible all are enumerated and
one is recommended.

---

## 0. ENG-0006-A corrections applied

Two corrections to the accepted ENG-0006-A report, both bookkeeping, neither
touching its substance or its review history.

| | Correction |
|---|---|
| **Gap count** | The introduction and §D said **ten** gaps while §J correctly enumerated **thirteen**. Both now say thirteen, and §D states where G11–G13 are set out. `SPECIFICATION_GAPS=13` in the result block was already correct. |
| **Fail-closed wording** | §F said that refusing a malformed health claim "leaves the candidate eligible" — the exact misreading the reviewer flagged. Corrected, and marked in place with a pointer to the new §Q. |

A new **§Q** records the reviewer disposition: ENG-0006-A accepted, the three
conflicts confirmed, G1–G13 confirmed as real findings, the twenty-one increments
accepted as planning input only, Health Runtime implementation not authorized.
§A–§P are unchanged — that checkpoint required review and got it, and the report
stands as what was found on 2026-10-12.

---

## 1. The wording discipline this package is held to

The reviewer's clarification is load-bearing and easy to lose, so it is stated
once here and obeyed in every finding below.

**Trust fails closed by denying authority.** A trust failure **removes**
eligibility. That is the correct behaviour for a layer that *grants*.

**Health fails closed on the health claim.** Health never grants, so there is no
authority for it to deny. When Health evidence is unreadable, unavailable,
malformed, unverifiable, stale, `unknown`, `unmonitored`,
`insufficient-policy` or `withheld`, the correct outcome is:

> **Health contributes no subtraction.**

**That is not a statement about eligibility.** Eligibility was never Health's to
confer or withhold. Trust standing, the twelve `ELIG` conditions, quarantine
(`ELIG-10`), `availability_intent` (`eligibility.py:624` requires `in-service`),
restricted scope, revocation and every other independent rule continue to decide
it with undiminished authority, and a candidate Health did not remove may still be
ineligible for any of them.

**Three phrasings are therefore banned from this package and from any future
implementation or test name**, because each converts an absence of health
evidence into a grant:

- "health failure makes the candidate eligible"
- "malformed health ⇒ eligible"
- "no health evidence ⇒ pass"

The permitted phrasing is **"no Health subtraction"**, and the §K test names use
it verbatim.

**The symmetry that makes this safe.** Health is fail-closed in *both*
directions, which is why "no subtraction" is not a weakness:

| Absent or unusable Health evidence | may never produce |
|---|---|
| a positive claim | `healthy`, `assumed-healthy`, `probably-available`, `no-known-issues`, `healthy-by-default` |
| a negative claim | a removal, a degradation event, or a recommendation treated as evidence |

An attacker who can corrupt, block or forge Health gains **neither** a grant
**nor** a denial. That is the property the whole layer is built to hold, and
`unknown_effect_on_eligibility: inert` is where the released schema already says
so.

---

## 2. Conflict resolutions

### C1 — the canonical health state set

| Field | Value |
|---|---|
| **FINDING_ID** | C1 |
| **CURRENT_ARCHITECTURE** | ADR-0013 line 153 declares "**Six states.**" with a six-row table at 155–162 omitting `insufficient-policy`. ADR-0013 line 379, in its own Accepted Consequences, calls `insufficient-policy` a visible **state**. `health-states.md` declares "Seven states" with a seven-row table. `operational-envelope.md` requires it per metric. `worked-examples.md` example 6 renders it. `selection-visibility.md` requires a warning for it. |
| **RELEASED_RUNTIME_CONSTRAINT** | `capability-health-state` `state` enum: **7** values; `inert_states` includes `insufficient-policy`. `capability-degradation-event` `from_state` and `to_state`: **7** each. `capability-health-envelope`: `absent_threshold_means: insufficient-policy`, `absent_threshold_never_means: healthy`. `tests/test-capability-health.sh:423` already asserts `len(health_states) == 7` — and the suite's 461 assertions pass, because none of them compares the schema to ADR-0013. |
| **SECURITY_CONSTRAINT** | Dropping `insufficient-policy` would collapse "an envelope exists but this metric has no declared threshold" into either `healthy` (a fabricated positive claim) or `unknown` (indistinguishable from a collection failure, and so repaired by fixing the wrong thing). The per-metric Null Policy Rule is the mechanism that stops a partially-declared envelope reporting its undeclared dimensions as satisfied. |
| **COMPATIBILITY_CONSTRAINT** | None. No production Health record exists, no runtime reads these enums, and the schemas already carry the seven-state position. |
| **OPTIONS_CONSIDERED** | **(a)** Correct ADR-0013 to seven, matching schemas and documents. **(b)** Correct the schemas and four documents down to six, removing `insufficient-policy`. **(c)** Keep both and declare `insufficient-policy` a sub-state of `unknown`. |
| **RECOMMENDED_RESOLUTION** | **(a).** Canonical set, in the order the schema declares them: `unknown`, `unmonitored`, `insufficient-policy`, `healthy`, `degraded`, `unavailable`, `withheld`. Default `unknown`. Positive-claim-supporting: `healthy` **only**. Inert on eligibility: `unknown`, `unmonitored`, `insufficient-policy`, `withheld`. Correct ADR-0013 line 153 to "Seven states" and add the row at 155–162 using the meaning already in `health-states.md` and the schema. |
| **WHY** | The disagreement is one-directional: every artefact except one ADR sentence and one ADR table already holds the seven-state position, and **ADR-0013 itself names the seventh state at line 379**. This is stale prose, not an open design question, which is exactly what the reviewer ruling says. Option (b) would delete a state that three schemas, four documents and a passing released assertion depend on, and would reintroduce the favourable-default failure the Null Policy Rule exists to prevent. Option (c) would make the state set depend on a hierarchy nothing declares, and `health-states.md` keeps `unknown` and `insufficient-policy` apart precisely because they call for different fixes — *fix the collection* versus *finish the envelope*. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | None — `capability-health-state`, `capability-degradation-event` and `capability-health-envelope` are already correct. |
| **ADRS_AFFECTED** | **ADR-0013**, line 153 and the table at 155–162. |
| **DOCS_AFFECTED** | None. `health-states.md` has one cosmetic residue: its "These are not trust states" table says "The **six** above" while its own header says seven. Worth correcting in the same pass; it changes no meaning. |
| **RUNTIME_SURFACES_AFFECTED** | None now. Future: the CHSTATE derivation and the health adapter's state vocabulary. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T1.** Extract the state set from ADR-0013's table, `health-states.md`'s table, the CHSTATE enum and both CHDEG enums, and assert all five are the same set. This is the test whose absence let C1 survive. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### C2 — the canonical recommendation vocabulary

| Field | Value |
|---|---|
| **FINDING_ID** | C2 |
| **CURRENT_ARCHITECTURE** | ADR-0013 line 244: "It may recommend **`investigate`** or **`drain`**. Nothing else." `governance-boundaries.md`: "a **closed vocabulary of exactly four**" — `investigate`, `review-envelope`, `verify-observation-source`, `consider-manual-drain`. |
| **RELEASED_RUNTIME_CONSTRAINT** | `capability-health-recommendation` `recommendation` enum: exactly those four. **`drain` is not a permitted value anywhere in the schema.** The schema's own header comment still repeats the two-kind phrasing. `is_action: false`, `advisory_only: true`, `requires_human_action: true`, `auto_execution: forbidden`, `vocabulary: closed`. |
| **SECURITY_CONSTRAINT** | The sharp edge is nominal, not just numeric. `drain` names an **act**; `consider-manual-drain` names a **consideration**, and `governance-boundaries.md` writes "**Consider, not do**". An implementer following line 244 literally would emit a value the schema rejects *and* would have named an operation rather than advice — which is the first step by which an advisory record acquires executable authority. The two missing kinds also carry real safety content: `review-envelope` and `verify-observation-source` are how the layer says "the threshold may be wrong" and "the measurement may be wrong" rather than "the subject is broken", which is the collection-failure distinction applied to advice. Without them, every finding reads as a subject fault. |
| **COMPATIBILITY_CONSTRAINT** | None. No CHREC exists. |
| **OPTIONS_CONSIDERED** | **(a)** Correct ADR-0013 to the four closed values. **(b)** Narrow the schema and `governance-boundaries.md` to two. **(c)** Keep four and add `drain` as a fifth synonym for `consider-manual-drain`. |
| **RECOMMENDED_RESOLUTION** | **(a).** Canonical closed vocabulary, exactly four: `investigate` · `review-envelope` · `verify-observation-source` · `consider-manual-drain`. Correct ADR-0013 line 244 to name all four and to name `consider-manual-drain` rather than `drain`. Correct the CHREC header comment to match its own enum. Every CHREC continues to carry `review_required`, `advisory_only`, a written `reason` and `derived_from_state_id`; the forbidden-field list stays exactly as released. |
| **WHY** | A vocabulary declared **closed** cannot be resolved by inference, so the conflict must be decided explicitly rather than by taking the longer list. Option (b) deletes two kinds that exist to separate a wrong threshold and a wrong measurement from a broken subject, and would push both into `investigate`, losing the distinction at the only point where it is actionable. Option (c) is the worst of the three: it admits the word `drain` into the vocabulary, and the argument for promoting it from a synonym to an executable kind "will be made during an incident" — the schema's own stated reason for closing the list. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | `capability-health-recommendation` — **comment only**, no enum or field change. |
| **ADRS_AFFECTED** | **ADR-0013**, line 244. |
| **DOCS_AFFECTED** | None. `governance-boundaries.md` is already correct. |
| **RUNTIME_SURFACES_AFFECTED** | None now. Future: CHREC emission. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T2.** Extract the vocabulary from ADR-0013, `governance-boundaries.md` and the CHREC enum; assert all three are the same set **and** that the token `drain` appears as a permitted value in none of them. Plus a standing assertion that the forbidden-field list still bars every execution surface by name. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### C3 — `withheld` semantics

Semantics only. **Who may create it is G6**, deliberately separated.

| Field | Value |
|---|---|
| **FINDING_ID** | C3 |
| **CURRENT_ARCHITECTURE** | ADR-0013 line 162: "`withheld` \| The operator set the host's availability intent to draining or withheld." The section immediately after it repudiates that: "These were the same thing in the first draft of this ADR, and that was wrong in a way worth recording… it makes a *health state* into a *selection control*." |
| **RELEASED_RUNTIME_CONSTRAINT** | `capability-health-state.withheld_semantics`: `means: health-conclusion-not-asserted-or-published`, `implies_healthy: false`, `implies_degraded: false`, `implies_unavailable: false`, `removes_eligibility: false`, `equivalent_to_do_not_select: false`, `may_set_availability_intent: false`, `availability_intent_may_influence_publication: true`. `withheld` is in `inert_states`. |
| **SECURITY_CONSTRAINT** | Under line 162 `withheld` is derived from a Fabric field and becomes a second, Health-owned name for a selection control — so a Health writer could influence selection by publishing a state. Under the corrected definition it removes nothing and sets nothing. The one-way influence must stay one-way: `availability_intent` **may** be a reason to stop publishing conclusions; Health **may never** set `availability_intent`. |
| **COMPATIBILITY_CONSTRAINT** | None. No Health record exists, and no Fabric record carries a health state. |
| **OPTIONS_CONSIDERED** | **(a)** Correct ADR-0013's table row to the published definition. **(b)** Remove `withheld` from the state set and express non-publication outside the state vocabulary. **(c)** Keep line 162 and derive `withheld` from `availability_intent`. |
| **RECOMMENDED_RESOLUTION** | **(a).** Canonical definition: **`withheld` means Health conclusions are intentionally not asserted or published for this subject.** It is not a finding about the subject; it implies neither `healthy`, `degraded` nor `unavailable`; it removes no eligibility and is **inert**; it is not a synonym for do-not-select; Health may never set `availability_intent`; and `availability_intent` may influence *whether Health publishes*, never *what Health concludes*. Replace the line-162 cell with exactly this. |
| **WHY** | Option (c) is the defect ADR-0013 documents itself having fixed, and an implementer who reads the table and stops would rebuild it. Option (b) is more tempting than it looks and is still wrong: removing the state leaves the layer with no way to say "we are deliberately not asserting", which the ADR names as the thing the first draft left it unable to express — and ADR-0013's own Accepted Risks already flag that this correction "may still prove thin". Thin is not the same as absent, and narrowing it now would discard a distinction whose value appears exactly when the two facts diverge: a published finding on a node nobody withdrew, or a withdrawn node still reporting `healthy`. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | None — `withheld_semantics` is already the corrected position. |
| **ADRS_AFFECTED** | **ADR-0013**, line 162. |
| **DOCS_AFFECTED** | None. `health-states.md` is already correct. |
| **RUNTIME_SURFACES_AFFECTED** | None now. Future: CHSTATE derivation must never read `availability_intent` as a source of `withheld`; the health adapter must treat `withheld` as no-subtraction. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T3.** Assert that ADR-0013's row, `health-states.md`'s definition and `withheld_semantics` agree on all eight properties; and a behavioural assertion, once a runtime exists, that `withheld` and `availability_intent` are independently settable and that no code path derives one from the other. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

---
## 3. Gap resolutions

### G1 — selection health disclosure

The largest decision in the package, and the one with a released immutable record
in its path. Designed below rather than summarised.

#### G1.1 What the released record can and cannot do

| Mechanic | Established at | Consequence for G1 |
|---|---|---|
| `SUPPORTED_SCHEMA_VERSION = "schott-platform/v1"` | `tools/fabric/models.py:36` | **One global API version for all eight Fabric families**, not a per-family version |
| A stored record whose version differs is **refused** | `models.py:296` — "stored record declares an unsupported schema version" | Bumping `schema_version` would make **every existing Fabric record unreadable**, across all eight families |
| `from_dict` refuses **unknown** keys, and never checks for **missing** ones | `models.py:303-307` | A **newly added field does not invalidate an older record** — the old record has no unknown key, it simply lacks the new one |
| `CapabilitySelection` already carries **seven** defaulted-`None` fields | `models.py:677-688` | Defaulted fields are the established shape for "absent in this record" |
| "An absent optional serialises as **absent** rather than as a null" | `models.py:674-676` | Absence is already a first-class serialisation state in this very record |
| `route_provenance: all-or-none`, enforced "where the outcome itself is known, in the evidence rules" | schema + `models.py:702` | A **conditionally-required group validated at write time** is an established pattern here |
| `excluded_candidates: tuple[Any, ...]`, entries `{"instance_id", "reasons"}` | `selection.py:550,557` | Candidate-level structure already exists — **for excluded candidates only** |
| Every candidate is judged, not short-circuited | `selection.py:552-554` | The record already "explains the whole field rather than stopping at the answer" |
| **The selected candidate gets no entry** | `selection.py:550-558` | Health disclosure about the **winner** has nowhere to live in the current shape — which is precisely the silence G1 is about |

**Therefore: `schema_version` is NOT sufficient, and is the wrong mechanism.**
The reviewer asked this explicitly. The Fabric's `schema_version` is a single
global gate shared by eight families and enforced by equality, so moving it to
make disclosure mandatory on `capability-selection` would invalidate every
`capability-definition`, `capability-contract`, `capability-package`,
`capability-host`, `capability-advertisement`, `capability-instance`,
`capability-route` and `capability-selection` record in production. That is a
migration-by-rewrite of the entire Fabric store, which the compatibility
requirement forbids outright.

**The platform already owns the right mechanism, and it was built in ENG-0005.**
Generation 23's `LATER_SCHEMA_MEMBERS` (`tools/capability/execution/provenance.py:86`)
exists for exactly this situation — a released immutable family gained a member,
and prior records lacking it must stay valid and comparable without being
rewritten. Its rules are the ones to reuse:

> "absence of a member named here is a **LEGACY RECORD SHAPE** and is skipped by
> the comparison. The set is **CLOSED**: a prior record missing anything NOT named
> here is a shape this runtime has no rule for, and that refuses on its schema
> rather than guessing. **Nothing is ever written back into an older record.**"

#### G1.2 Where disclosure belongs

**A combination of selection-level context and candidate-level result.** One
subject-level `health_state` field is insufficient, and the reviewer is right to
say so: a selection considers several candidates which may hold different health
states, and the single most important fact — *was Health consulted at all* — is a
property of the selection, not of any candidate.

**Selection-level context** (one per record) answers "what did Health contribute
to this decision as a whole":

| Field | Meaning |
|---|---|
| `consulted` | `true` / `false`. **`false` is the honest value for every selection made before a Health runtime exists**, and it is what distinguishes "not consulted" from "consulted and silent" |
| `evaluated_at` | the instant Health standing was read, supplied by the caller, never read from a clock by the adapter |
| `adapter_outcome` | `answered` · `unreadable` · `unavailable` · `malformed` — the adapter's own status, from a closed vocabulary |
| `effect` | `removed-at-least-one` / `none`. A selection-level roll-up of whether Health subtracted anything |
| `warning` | required whenever `effect` is `none` and any candidate's state is not `healthy`, which is the "must never silently disappear" rule made structural |

**Candidate-level result** (one entry per *considered* candidate, selected and
excluded alike) answers "what did Health say about this one":

| Field | Meaning |
|---|---|
| `instance_id` | the candidate |
| `health_state` | one of the seven, **or** `not-consulted` when selection-level `consulted` is false |
| `health_freshness` | `current` · `aging` · `stale` · `unknown`, **per the dimensions that mattered**, never a single collapsed subject age |
| `health_effect` | `removed` / `none` — for this candidate |
| `envelope_id`, `envelope_version` | where applicable, so a later supersession cannot change what a past selection meant |
| `warning` | required whenever `health_state` is not `healthy` |
| `evidence_unusable_reason` | present only when the input was malformed, unreadable, unverifiable or unavailable, from a closed vocabulary |

**Why candidate-level entries must cover the selected candidate too.** The
current record gives an entry only to *excluded* candidates, so a winner about
which Health said nothing is indistinguishable from a winner Health endorsed —
the exact defect. A new `candidate_health` sequence covering **all** considered
candidates is therefore required; extending `excluded_candidates` alone would
leave the winner silent and would not fix the finding.

#### G1.3 The nine health-input cases, each distinguishable

| # | Case | selection `consulted` | `adapter_outcome` | candidate `health_state` | candidate `health_effect` | warning |
|---|---|---|---|---|---|---|
| 1 | Health not consulted | `false` | — | `not-consulted` | `none` | **required** |
| 2 | Consulted, no current conclusion | `true` | `answered` | `unknown` | `none` | **required** |
| 3 | Consulted, current healthy | `true` | `answered` | `healthy` | `none` | not required |
| 4 | Consulted, current degraded | `true` | `answered` | `degraded` | per G11 | **required** |
| 5 | Consulted, current unavailable | `true` | `answered` | `unavailable` | `removed` | **required** |
| 6 | Consulted, withheld | `true` | `answered` | `withheld` | `none` | **required** |
| 7 | Consulted, insufficient-policy | `true` | `answered` | `insufficient-policy` | `none` | **required** |
| 8 | Consulted, stale evidence | `true` | `answered` | the prior finding, e.g. `degraded` | `none` — stale never subtracts | **required**, naming the age |
| 9 | Malformed / unreadable / unverifiable | `true` | `malformed` · `unreadable` · `unavailable` | `unknown` | **`none`** | **required**, with `evidence_unusable_reason` |

**Cases 1, 2 and 3 are the heart of the finding.** All three end with
`health_effect: none` and in the released record all three are byte-identical.
Under this design they are distinguished by `consulted` plus `health_state` plus
the presence of a warning, which is what `selection-visibility.md`'s three-case
table demands when it says the cases "produce the same eligibility outcome and
mean opposite things".

**Case 9 is where the wording discipline bites.** A malformed Health input
produces **no Health subtraction** and a conspicuous disclosure. It does **not**
make the candidate eligible — eligibility is decided by the twelve `ELIG`
conditions, quarantine, `availability_intent`, scope and revocation, all of which
ran before Health was consulted at all.

#### G1.4 The five selection shapes

| Shape | Disclosure |
|---|---|
| **Selected candidate** | A `candidate_health` entry is **required** for it. This is the case the released record cannot express. |
| **Candidate removed by Health** | Entry with `health_effect: removed`, plus the existing `candidate-removed-by-health-input` reason in `excluded_candidates.reasons`. The two must agree, and a cross-check asserting that is cheap. |
| **Candidate removed for another reason before Health matters** | Entry with the health state **as observed** and `health_effect: none`. Health is consulted *after* eligibility (`selection.py:370`), so a candidate already excluded by trust, locality or contract carries a health state that changed nothing. Recording it as `none` rather than omitting it keeps "health never disappears" true without implying health agreed. |
| **Refusal / no candidate selected** | Selection-level context is **still required**, and a `candidate_health` entry for every considered candidate. A refusal is a first-class outcome here (`records_refusal: true`), and "why did nothing run" needs health's contribution as much as "why did this run there". When no route resolved there are no candidates, so the sequence is empty and the selection-level block still records `consulted` and `adapter_outcome`. |
| **Multiple candidates, different health states** | One entry each, independently stated. No roll-up to a single subject-level state; the selection-level `effect` is a roll-up of *effect* only, never of *state*. |

#### G1.5 The forward-only version boundary

**Mechanism: a new defaulted field plus a closed later-member declaration plus
write-time enforcement. `schema_version` does not move.**

1. **Add** `health_disclosure` and `candidate_health` to `CapabilitySelection` as
   dataclass fields defaulting to `None`, following the seven defaulted fields
   already there. Existing records load unchanged: they carry no unknown key, and
   the absent fields take their defaults.
2. **Declare** both in a **closed** later-member set on the Fabric side, modelled
   on `LATER_SCHEMA_MEMBERS` — absence is a declared legacy shape, not a defect;
   absence of anything *not* named refuses on shape rather than being guessed at.
3. **Enforce presence at write time**, in the evidence rules where
   `route_provenance: all-or-none` is already judged — "where the outcome itself
   is known". A *new* selection cannot be written without disclosure; an *old*
   selection is never rewritten.
4. **Nothing is ever written back into an older record.**

**Reading an old record states its shape rather than inventing a value.** A
pre-disclosure CSEL must read back as `health_disclosure: absent (pre-disclosure
record)` — **never** as `consulted: false` and never as `health_state: unknown`,
because both would be this runtime asserting something about a decision made
before the field existed. The five production records are *historical evidence of
selections made with no Health runtime in existence*, which is a true and
sufficient description.

| Field | Value |
|---|---|
| **FINDING_ID** | G1 |
| **CURRENT_ARCHITECTURE** | `selection-visibility.md` requires six exposures on "**Every** Capability Selection" and claims "The Fabric's selection schema **carries the requirement as a declared block**". ADR-0013: "**Health must never silently disappear from the explanation.**" |
| **RELEASED_RUNTIME_CONSTRAINT** | `capability-selection.schema.yaml` carries **no such block**; health appears only as `health_score` in `forbidden_fields`. `select_candidate` takes `health_removals`, folds it into the request digest (`selection.py:461`) and records its effect only as an exclusion reason on a removed candidate. `health_removals` is **not reachable from the CLI**. Full mechanics in §G1.1. |
| **SECURITY_CONSTRAINT** | Three. **(i)** Silence is the attack surface: if "health said nothing" is indistinguishable from "health agreed", suppressing a collector buys an endorsement. **(ii)** Disclosure must never be writable by anything that could benefit — it is derived by the Fabric from an adapter answer, never supplied by a caller or a subject. **(iii)** The malformed case must disclose conspicuously and subtract nothing, or corrupting the Health store becomes a route-emptying denial of service. |
| **COMPATIBILITY_CONSTRAINT** | **Binding.** Five immutable production records — `CSEL-000001`…`CSEL-000005` — must remain valid, unchanged and uninterpreted. `schema_version` cannot move (§G1.1). No migration by rewrite. |
| **OPTIONS_CONSIDERED** | **(a)** Bump `schema_version` — **rejected outright**: it is global across eight families and enforced by equality, so it invalidates the entire Fabric store. **(b)** Add optional fields only — rejected: optional-and-absent *is* the silent case, so a conforming runtime could still say nothing. **(c)** A separate side record linking to a CSEL — rejected: it leaves the selection record itself silent, and "why did this run there" is answered by the selection record by design. **(d)** Subject-level single `health_state` field — rejected: cannot express multiple candidates with different states, nor the selected-versus-excluded distinction. **(e)** Defaulted fields + closed later-member declaration + write-time enforcement, selection-level context plus candidate-level results. |
| **RECOMMENDED_RESOLUTION** | **(e)**, as designed in §G1.2–§G1.5. |
| **WHY** | It is the only option that makes disclosure **mandatory going forward** while leaving the five existing records **valid, unchanged and not reinterpreted** — and it is not invented: every component is a pattern the platform already runs. Defaulted fields and absent-serialises-as-absent are already in this record; a conditionally-required group validated in the evidence rules is already in this record as `route_provenance`; a closed later-member set that treats absence as a legacy shape and never writes back is Generation 23, built in ENG-0005 for this exact problem. The selection-plus-candidate split is forced by the reviewer's own case list: `consulted` is a property of the selection and `health_state` is a property of a candidate, and no single field can carry both. |
| **RECORDS_AFFECTED** | `capability-selection` — **new records only**. |
| **SCHEMAS_AFFECTED** | `capability-selection.schema.yaml`: a `health_disclosure` block and a `candidate_health` structure, declared conditionally-required from the later-member boundary forward; `health_score` stays forbidden. |
| **ADRS_AFFECTED** | **ADR-0012** owns `capability-selection`; **ADR-0013** owns the requirement. Which carries the change is the reviewer's call — recommendation: a short ADR-0012 amendment for the record shape, citing ADR-0013 for the requirement, so neither ADR describes a record it does not own. |
| **DOCS_AFFECTED** | `selection-visibility.md` — **the stale claim must be corrected**: the released schema does **not** carry the block. Recommended wording: state it as a requirement on a declared future schema boundary, name the boundary, and record that pre-boundary records are historical evidence of selections made with no Health runtime in existence. |
| **RUNTIME_SURFACES_AFFECTED** | `tools/fabric/models.py` (`CapabilitySelection` fields, later-member set), `tools/fabric/selection.py` (build the block; entry for the selected candidate), `tools/fabric/evidence.py` (write-time enforcement), the future `health_adapter`, and the Fabric CLI, which must expose health input at all — it currently cannot. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** Five CSEL records remain byte-identical, remain loadable (no unknown keys), and are read as pre-disclosure records rather than assigned a default meaning. |
| **MIGRATION_REQUIRED** | **No.** Forward-only. Nothing is written back. |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T7.** Assert `selection-visibility.md`'s exposure list, the schema block and the record builder agree; that all nine §G1.3 cases are distinguishable in a written record; that a new selection **cannot** be written without disclosure; that each of the five existing production records still loads and reports as pre-disclosure; that a candidate with `health_effect: removed` also carries the `candidate-removed-by-health-input` reason, and the converse; and that `health_score` remains refused. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G2 — evidence and derivation relationships

| Field | Value |
|---|---|
| **FINDING_ID** | G2 |
| **CURRENT_ARCHITECTURE** | CHSTATE and CHDEG **require** `derived_from_observation_ids`; CHREC **requires** `derived_from_state_id` and optionally `derived_from_event_id`. ADR-0013: states "carry the observation identifiers they were derived from, so the evidence behind any past assessment stays reachable". |
| **RELEASED_RUNTIME_CONSTRAINT** | `DERIVED_FROM.allowed_sources` = `[verification, knowledge-event, observation, trust-record, trust-decision]` — **no Health record is an allowed source**, though `capability-health-observation` and `capability-health-state` are allowed **targets**. Enumerated across every relationship type: edges permitting `CHSTATE→CHOBS`, `CHDEG→CHOBS` and `CHREC→CHSTATE` are **NONE**. The four Health relationships cover subject (`OBSERVES_HEALTH_OF`, `HEALTH_STATE_OF`, `RECOMMENDS_ACTION`) and envelope (`EVALUATED_AGAINST`) and none covers evidence. |
| **SECURITY_CONSTRAINT** | **The decisive one.** `DERIVED_FROM` carries `forbidden_source_target_pairs` barring `trust-record` and `trust-decision` from citing `capability-health-observation` or `capability-health-state` — ADR-0011's directionality rule, declared per-pair because the flat lists cannot express it. Widening `allowed_sources` lengthens the list those four pairs must keep covering, and **any future widening of `allowed_targets` to include trust records would silently open a Health→Trust path** that no existing forbidden pair blocks. The rule is *source trust, target health*; a symmetric mistake is unguarded. |
| **COMPATIBILITY_CONSTRAINT** | None. No Health record and no Health relationship instance exists. |
| **OPTIONS_CONSIDERED** | **(a)** Widen `DERIVED_FROM.allowed_sources` with the three Health types. **(b)** Add dedicated Health relationship types — `DERIVED_FROM_OBSERVATIONS` (CHSTATE·CHDEG → CHOBS) and `FOLLOWS_FROM_STATE` (CHREC → CHSTATE·CHDEG). **(c)** Both. **(d)** Leave the ontology silent and rely on field-level references. |
| **RECOMMENDED_RESOLUTION** | **(b) — dedicated Health relationship types**, with `DERIVED_FROM` left exactly as released. Two new edges: `DERIVED_FROM_OBSERVATIONS`, sources `[capability-health-state, capability-degradation-event]`, targets `[capability-health-observation]`; and `FOLLOWS_FROM_STATE`, sources `[capability-health-recommendation]`, targets `[capability-health-state, capability-degradation-event]`. Both `transitive: false`. Neither admits any trust type as source or target, so the Health→Trust direction has no edge to travel on **by construction** rather than by exclusion. |
| **WHY** | The reviewer asked whether widening is safe or whether dedicated types give stronger governance, and the answer is dedicated types — for a reason that is structural rather than stylistic. `DERIVED_FROM` is the platform's **general** provenance edge, shared with verification, knowledge and trust, and it already needs a hand-maintained per-pair exclusion list to keep Trust away from Health. Adding Health as a source makes that shared edge carry both the Health evidence chain and the Trust provenance chain, so the single thing standing between them stays a list someone must remember to extend. Dedicated edges whose source and target sets contain **no trust type at all** cannot express a Trust→Health derivation however they are widened later, which converts a maintained prohibition into an absent capability. The cost is two catalog entries. Option (a) is smaller and strictly weaker; option (d) leaves the one chain ADR-0013's audit section rests on ungoverned. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | None — the required fields already exist. |
| **ADRS_AFFECTED** | **None.** ADR-0013 already states the requirement; only the catalog omits the means. |
| **DOCS_AFFECTED** | None required. |
| **RUNTIME_SURFACES_AFFECTED** | `platform-model/ontology/relationship-types.yaml`; future relationship validation. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T6.** Assert every `derived_from_*` field on the six schemas has a permitting edge; assert **no** edge admits a trust type as source with a Health type as target **or** a Health type as source with a trust type as target — both directions, so the symmetric gap named above is closed by test; and assert the four existing `DERIVED_FROM` forbidden pairs are still present. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G3 — condition grammar

#### G3.1 The shape decision, before the content

**The grammar should not be a string grammar.** The exemplars are free text
(`"p95 > 2000ms"`, `"> 32"`), and the smallest thing that satisfies "same inputs,
same state, every time" is to **replace the string with a structured
declaration** so that no parser exists to disagree with itself. A parser is a
policy surface: every accepted token is a semantic commitment, and a rejected one
makes an operator's envelope silently unenforceable.

Proposed dimension entry — a closed set of keys, no expression text anywhere:

```yaml
dimension: latency
unit: milliseconds
aggregation: { kind: instant }
entry_condition: { operator: gt, value: "2000" }
exit_condition:  { operator: le, value: "1500" }
hysteresis: { kind: duration, seconds: 120 }      # see G4
freshness_policy_seconds: 60                       # null permitted
```

#### G3.2 The grammar

| Element | Specification |
|---|---|
| **Comparison operators** | Closed, five: `gt` · `ge` · `lt` · `le` · `eq`. No `ne`, no ranges, no boolean combinators, no negation. A dimension needing two bounds declares two dimensions or uses `entry`/`exit` asymmetry, which is what they are for. |
| **Numeric representation** | A **decimal string**, compared as an exact decimal. Not a float: `0.1` must not depend on binary representation, and a threshold that compares differently on two hosts is not deterministic. Integers are decimal strings with no fractional part. |
| **Units** | A closed vocabulary per dimension, declared once in the schema. The envelope's `unit` **must equal** the observation's `unit` for that dimension; a mismatch is a **refusal**, never a conversion. Implicit unit conversion is how `2000ms` and `2s` become a silent disagreement. |
| **Dimension/unit compatibility** | A declared table: `latency`→`milliseconds`; `queue-depth`→`items`; `success-count`/`failure-count`→`count`; `cpu-`/`memory-`/`gpu-`/`vram-utilization`→`percent`; `storage-pressure`→`percent`; `availability`→`boolean`; `heartbeat-freshness`/`collector-freshness`→`seconds`; `transport-health`→`boolean`. A dimension declared with the wrong unit is refused at envelope authoring time, not at evaluation time. |
| **Aggregation types** | Closed, **two**: `instant` and `windowed_count`. Nothing else in v1. |
| **Instant semantics** | Evaluate the **single newest observation** for that dimension whose `collection_status` is `collected` and whose age is within `freshness_policy_seconds`. If there is none, the dimension is **`unknown`** — never `healthy`, never `degraded`. |
| **Windowed semantics** | `{ kind: windowed_count, window_seconds: n, min_samples: m }`. Applies only to `success-count` and `failure-count`, which the observation model already defines as "outcomes over a declared window". The comparison applies to the **count of qualifying observations** within the window. |
| **Minimum samples** | `min_samples` is **required** on `windowed_count`. A window holding fewer than `min_samples` usable observations yields **`unknown`** for that dimension. Without this, one sample in an empty window is a verdict. |
| **Window boundary semantics** | Half-open, **start-inclusive / end-exclusive**, anchored at the evaluation instant: `[evaluated_at − window_seconds, evaluated_at)`. This reuses the platform's existing declared convention — `capability-route`'s `overlap_window_structure` already specifies `boundaries: start-inclusive-end-exclusive` — rather than inventing a second one. |
| **Missing samples** | Not an input. Absence contributes neither satisfaction nor violation, and is the reason `min_samples` exists. |
| **Collection failures** | An observation whose `collection_status` is `failed` or `unavailable` has **no `measured_value`** and is **excluded from every aggregation**. It is never counted as a violation and never as compliance. This is `collection_failure_implies_subject_failure: false` enforced arithmetically rather than promised in prose. |
| **Mixed-source observations** | Deferred to **G9**, which owns source identity. The rule proposed there — contradicting fresh observations of one dimension from different sources yield `unknown` with both cited — is the input to this grammar, and this grammar must not resolve contradictions itself. |
| **Ordering** | By `observed_at` ascending; ties broken by `observation_id` ascending. Both are total and recorded, so "newest" is never ambiguous. |
| **Deterministic rounding** | **None required, by construction.** The v1 grammar performs no division, no averaging and no interpolation, so no rounding rule is needed. That is a deliberate consequence of the aggregation set, not an omission. |
| **Combination across dimensions** | Unchanged: `worst-dimension-wins`, already declared on the envelope schema. |

#### G3.3 Reconciling `p95 > 2000ms`

**Recommendation: percentile aggregation is NOT supported in v1, and
`worked-examples.md` should be corrected.**

Three reasons, in order of weight:

1. **It is not expressible against the released observation model.** CHOBS is "one
   measurement, of one dimension, of one subject, at one **moment**", and
   `sample_window_seconds` is optional. `p95` needs a sample set, and nothing
   declares which observations form it.
2. **"p95" is not one definition.** Nearest-rank, linear interpolation, and
   exclusive versus inclusive conventions give different answers on the same
   samples, and the difference is largest on small sets — exactly the regime a
   fleet of a few instances lives in. An implementer choosing a convention would
   be authoring the threshold's meaning, which principle 7 reserves to a human.
   Declaring the convention in the envelope is possible, and it is more policy
   surface than v1 needs.
3. **Hysteresis already does the job p95 was reaching for.** The reason to want a
   percentile is to avoid degrading on one slow response — and that is precisely
   what hysteresis is required for: "A subject that crosses a boundary once has
   not degraded." `{instant, gt, 2000}` with `{duration, 120}` expresses "latency
   has been over 2000ms for two minutes", which is the operationally meaningful
   claim, needs no sample set, and is reproducible from cited observations by
   inspection.

Proposed correction to `worked-examples.md` example 6: restate
`entry_condition: "p95 > 2000ms"` as the structured instant form, and
`queue_depth: "> 32"` as `{operator: gt, value: "32"}` with `unit: items`.
**Percentiles remain additively available later** — a future `percentile`
aggregation with a required, named interpolation convention would not invalidate
any v1 envelope.

| Field | Value |
|---|---|
| **FINDING_ID** | G3 |
| **CURRENT_ARCHITECTURE** | `entry_condition` and `exit_condition` are **required** on every envelope dimension with no declared type, grammar, operator set or evaluation semantics. ADR-0013 requires determinism; `degradation-semantics.md` requires reproducibility from cited evidence. |
| **RELEASED_RUNTIME_CONSTRAINT** | No runtime evaluates them. CHOBS is a single measurement at one moment with optional `sample_window_seconds`; CHDEG requires `entry_condition` **quoted from the envelope** so the event stays readable after supersession — which a structured value satisfies at least as well as a string. |
| **SECURITY_CONSTRAINT** | A permissive grammar is a threshold-manipulation surface: an expression language admits conditions whose effect an operator cannot predict by reading them, and `violation_widens_threshold: false` is unenforceable against a condition nobody can evaluate by hand. A string grammar additionally invites an accept-anything parser, where a malformed condition silently never fires and the dimension looks governed while being inert. |
| **COMPATIBILITY_CONSTRAINT** | None — no envelope exists. Choosing structure now avoids ever migrating authored strings. |
| **OPTIONS_CONSIDERED** | **(a)** Structured closed grammar, two aggregations, no percentiles. **(b)** Structured grammar plus percentile with a declared interpolation convention. **(c)** A string mini-language with a published BNF. **(d)** Keep free text and require a human-reviewed evaluator per dimension. |
| **RECOMMENDED_RESOLUTION** | **(a)**, as specified in §G3.1–§G3.3. |
| **WHY** | It is the smallest construct that satisfies determinism, and it removes the parser rather than specifying one — a condition that cannot be mis-parsed cannot be mis-enforced. Dropping division from the aggregation set eliminates rounding as a topic entirely, which is a real reduction in specification surface rather than a deferral. Option (b) is defensible and strictly larger; it should wait for a subject whose envelope genuinely cannot be written in instant form. Option (c) buys expressiveness nothing has asked for and costs a parser, a test corpus and a versioning story for the language itself. Option (d) is not determinism — it is determinism per installation. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | `capability-health-envelope` — structured `entry_condition`/`exit_condition`, closed operator set, aggregation block, dimension/unit table. `capability-degradation-event` — `entry_condition` becomes the quoted structured value. |
| **ADRS_AFFECTED** | **A new ADR**, carrying the condition grammar and (with G4) the hysteresis forms. It is a new normative policy language and does not belong inside ADR-0013's prose. |
| **DOCS_AFFECTED** | `operational-envelope.md` (dimension field table), `worked-examples.md` (example 6, example 7's `latency entry` strings), `degradation-semantics.md` (what "quoted from the envelope" now means). |
| **RUNTIME_SURFACES_AFFECTED** | Future: the condition evaluator, envelope authoring validation, CHSTATE derivation. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T4.** Assert the operator set in the new ADR, the envelope schema and the evaluator agree exactly; assert the dimension/unit table agrees between schema and ADR; assert no envelope admits an expression string; assert a unit mismatch refuses; assert a `windowed_count` without `min_samples` refuses; assert `worked-examples.md` contains no unstructured condition. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G4 — hysteresis grammar

| Field | Value |
|---|---|
| **FINDING_ID** | G4 |
| **CURRENT_ARCHITECTURE** | `hysteresis` is a **required** dimension field. `operational-envelope.md` defines it as "How long **or how often** the condition must hold". ADR-0013: "Hysteresis is **required**, not optional." `degradation-semantics.md`: "A transition that cannot show its hysteresis was satisfied is **not recordable**." |
| **RELEASED_RUNTIME_CONSTRAINT** | CHDEG's only hysteresis field is the **optional** `hysteresis_satisfied_over_seconds` — a duration. The "how often" half has nowhere to be recorded, so an occurrence-count transition could not evidence itself and by the architecture's own rule would not be recordable. |
| **SECURITY_CONSTRAINT** | An unprovable transition is the risk. A CHDEG an operator cannot reproduce from cited evidence is one they cannot argue with, which during a review is indistinguishable from a fabricated one. Whatever forms exist must each carry their own proof field. |
| **COMPATIBILITY_CONSTRAINT** | None. |
| **OPTIONS_CONSIDERED** | **(a)** `duration` only, in v1. **(b)** `duration` + `occurrences within a window`. **(c)** Free-form, as today. |
| **RECOMMENDED_RESOLUTION** | **(a) — `duration` only for ENG-0006 v1.** Form: `{kind: duration, seconds: n}`, `n > 0`, required on every dimension. The condition must hold on **every** usable observation across a continuous span of at least `n` seconds, with at least one usable observation at or after `evaluated_at − n`. CHDEG must record, as **required** fields: the resolved `hysteresis` declaration, `hysteresis_satisfied_over_seconds`, the **first** and **last** observation identifiers in the satisfying span, and the count of usable observations in it. Promote `hysteresis_satisfied_over_seconds` from optional to required. |
| **WHY** | The reviewer asked whether both forms are necessary for v1 and preferred less expressive power. They are not. `duration` subsumes the operational intent of `occurrences` for every dimension in the released enum: with `instant` conditions and a duration hysteresis, "latency over 2000ms for two minutes" and "unavailable for ninety seconds" are both expressible, and the `success-count`/`failure-count` dimensions already carry their own window through `windowed_count`, so "how often" is expressed in the **condition** rather than in the hysteresis. Supporting both would mean two proof shapes on CHDEG, two evaluation paths, and a discriminator — for a case nothing has yet needed. `occurrences` remains additively available later: adding a second `kind` with its own required proof field invalidates no v1 envelope. Option (c) is what G4 is. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | `capability-health-envelope` (structured `hysteresis`); `capability-degradation-event` (required proof fields, `hysteresis_satisfied_over_seconds` promoted to required). |
| **ADRS_AFFECTED** | The **new grammar ADR** shared with G3. ADR-0013's "how long or how often" phrasing is narrowed, which is a normative change the reviewer must accept. |
| **DOCS_AFFECTED** | `operational-envelope.md` (the `hysteresis` row — "how long or how often" becomes "how long" in v1, with the reason), `degradation-semantics.md` (what the event must record). |
| **RUNTIME_SURFACES_AFFECTED** | Future: transition evaluation, CHDEG construction. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T5.** Assert the hysteresis forms in the ADR, the envelope schema and CHDEG's required fields agree; assert an unsatisfied hysteresis produces **no** transition; assert a satisfied one produces exactly one; assert a CHDEG missing any hysteresis proof field is **refused**; assert `occurrences` is rejected in v1 rather than silently ignored. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G5 — evaluation trigger, and freshness at two different times

| Field | Value |
|---|---|
| **FINDING_ID** | G5 |
| **CURRENT_ARCHITECTURE** | Nothing specifies when a CHSTATE is derived. ADR-0013 excludes an evaluation loop from its own release, correctly for an architecture-only release, leaving the decision here. CHSTATE requires `freshness` and `evaluated_at`, and is `append_only_history: true`, superseded never edited. |
| **RELEASED_RUNTIME_CONSTRAINT** | No evaluator exists. The released immutable-store contract makes an in-place freshness update impossible by design: a stored record cannot be edited, so a stored `freshness` can only ever be a statement about `evaluated_at`. |
| **SECURITY_CONSTRAINT** | **The trap the reviewer names.** A stored `freshness: current` must not remain operationally current forever because its label says so. If selection trusted the stored label, an attacker — or simple collector death — could freeze a favourable assessment permanently, and a six-month-old `healthy` would keep reading as fresh. Equally, a stored `degraded` must not age into irrelevance: `unknown` must never clear a prior finding. |
| **COMPATIBILITY_CONSTRAINT** | None. |
| **OPTIONS_CONSIDERED** | **(a)** Explicitly invoked only. **(b)** Observation-triggered. **(c)** Scheduled daemon. **(d)** Read-time derivation, nothing stored. **(e)** Explicitly invoked for storage + recomputed freshness at read. |
| **RECOMMENDED_RESOLUTION** | **(e).** **Stored at evaluation:** the CHSTATE record — `state`, `envelope_id`, `envelope_version`, `derived_from_observation_ids`, `reason`, `evaluated_at`, and `freshness` **as it stood at `evaluated_at`**, which is a historical fact and the thing an incident review needs. **Recomputed at selection:** the health adapter recomputes current freshness from each cited observation's `observed_at` and its dimension's `freshness_policy_seconds` against the caller's evaluation instant, and **never** trusts the stored `freshness` label for an eligibility decision. **The subtraction rule:** a candidate may be subtracted only when the *recomputed* freshness is `current` **and** the state is positively `degraded` or `unavailable`. A CHSTATE whose evidence has aged past policy contributes **no subtraction** — and still does not become `healthy`, and still does not clear its finding. No daemon in v1. |
| **WHY** | It is the only option that keeps both halves true: append-only history needs a stored record, and operational correctness needs a freshness that cannot be frozen. The division falls out of what each value *is* — `freshness` at `evaluated_at` is history and belongs in the record; freshness at selection time is a fact about now and must be computed now. Option (d) cannot satisfy `append_only_history: true` and leaves nothing to audit. Option (c) adds a daemon the architecture never asked for, and a background writer is a new privileged actor to defend. Option (b) couples evaluation to collection, so a collector outage stops state derivation at exactly the moment a state change matters most. Option (a) alone is sound but leaves freshness ambiguous, which is the defect this resolution exists to close. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | `capability-health-state` — a comment-level clarification that stored `freshness` is `freshness at evaluated_at`. Possibly a `freshness_evaluated_at` for exactness; `evaluated_at` already carries it, so recommended **not** to add a field. |
| **ADRS_AFFECTED** | **ADR-0013** — an evaluation-trigger and freshness-recomputation statement. Smallest form: a short subsection, since the ADR already says a state without an age is not an assessment and this says *which* age. |
| **DOCS_AFFECTED** | `unknown-and-freshness.md` — add the two-times distinction explicitly. It currently says freshness is evaluated independently per observation, which is necessary and not sufficient. |
| **RUNTIME_SURFACES_AFFECTED** | Future: derivation entry point, `health_adapter` (recomputation), CLI. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T8.** Assert a stored `freshness: current` whose evidence has aged past policy yields **no Health subtraction** and is **not** read as `healthy`; assert a stored `degraded` whose evidence has aged does not become `healthy` and does not subtract; assert re-derivation appends rather than edits; assert no code path reads stored `freshness` to decide a subtraction; assert no background writer exists. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G6 — `withheld` creation authority

| Field | Value |
|---|---|
| **FINDING_ID** | G6 |
| **CURRENT_ARCHITECTURE** | Nothing says who or what sets `withheld`. The only related statement is permissive: `availability_intent` "**may** influence whether Health evaluates or publishes"; schema `availability_intent_may_influence_publication: true`. C3 settles what `withheld` *means*; this settles who may cause it. |
| **RELEASED_RUNTIME_CONSTRAINT** | No Health record exists. CHENV is the **only** human-authored Health family — `authored_by: human`, `change_requires: immutable-approval`, four-digit identifiers "because human-declared". The other five are machine-generated. |
| **SECURITY_CONSTRAINT** | Three requirements. **(i)** It must not be derivable from `availability_intent`, which is C3's defect. **(ii)** It must not masquerade as evidence-derived health: a `withheld` state must be distinguishable from a `healthy`/`degraded`/`unavailable` state *by its provenance*, not only by its value, or a Health writer could suppress findings while appearing to publish them. **(iii)** It must not become a Fabric control: suppressing publication must remove nothing, which `removes_eligibility: false` already states. |
| **COMPATIBILITY_CONSTRAINT** | None. |
| **OPTIONS_CONSIDERED** | **(a)** A seventh persistent record family, e.g. `capability-health-withholding`. **(b)** A human-authored field on **CHENV**, the existing human-authored family — a `publication` block declaring `withheld` with an authoring identity, an approval and a reason, superseded by a new envelope version like every other envelope change. **(c)** Derive from `availability_intent` — **forbidden by C3**. **(d)** Leave `withheld` unreachable in v1: define its meaning, author nothing, and let the state exist in the vocabulary without a producer. |
| **RECOMMENDED_RESOLUTION** | **(b)**, with **(d)** as the explicitly acceptable fallback if the reviewer prefers to ship no producer at all in v1. Under (b): CHENV gains an optional `publication` block — `{ asserted: false, reason: <written>, approved_by: <identity>, approved_at: <instant> }`. When the envelope in force for a subject declares `asserted: false`, derivation emits `state: withheld`, citing the envelope and version, with **no** `derived_from_observation_ids` beyond what it would otherwise carry and an explicit provenance marker that this state is **declared, not derived**. Supersession is the existing envelope mechanism: withholding and resuming are both new envelope versions, so the history of who suppressed publication and when is immutable and attributable without a new family. |
| **WHY** | The reviewer asked to prefer not creating a seventh family unless the authority model cannot be represented safely otherwise, and it can. Withholding is a **policy** decision about a subject, which is exactly what an envelope already is, and CHENV already carries the four properties required: human-authored, immutable, superseding rather than mutable, and with an approving identity (`change_requires: immutable-approval`). It cannot mutate the Fabric because no Health record can. And it satisfies constraint (ii) cleanly: a `withheld` state is the only state whose provenance is an envelope declaration rather than observations, so "declared, not derived" is checkable rather than asserted. The cost is honest and worth naming: it attaches a *publication* decision to a record whose stated job is *limits*, and ADR-0013's own Accepted Risks already warn that `withheld` "may be a layer whose publication rules belong somewhere else". If the reviewer judges that mixing the two concerns on CHENV is worse than a seventh family, option (a) is the alternative and should be decided here rather than discovered during implementation. Option (d) is genuinely safe and the smallest of all — it ships the vocabulary with no producer — and is preferable to guessing. |
| **RECORDS_AFFECTED** | None existing. Future: CHENV, CHSTATE. |
| **SCHEMAS_AFFECTED** | `capability-health-envelope` (optional `publication` block); `capability-health-state` (a provenance marker distinguishing declared `withheld` from derived states). |
| **ADRS_AFFECTED** | **ADR-0013** — a statement of withholding authority. |
| **DOCS_AFFECTED** | `health-states.md` and `operational-envelope.md`. |
| **RUNTIME_SURFACES_AFFECTED** | Future: envelope authoring, CHSTATE derivation. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes — T3b.** Assert no code path derives `withheld` from `availability_intent`; assert a declared `withheld` carries an authoring identity and an approval; assert a `withheld` state is distinguishable from a derived state by provenance; assert `withheld` removes nothing; assert withholding cannot set `availability_intent`. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G7 — heartbeat trust model, replay and receipt time

#### G7.1 Why neither timestamp alone is sufficient

The two obvious designs each fail, and seeing both fail is what fixes the rule.

- **Freshness from the subject's `observed_at`:** the subject chooses the number
  that decides its own liveness. It can claim any instant.
- **Freshness from a Health-authored `received_at`:** a **replayed** old
  heartbeat arrives *now* and therefore reads as fresh. The subject refreshes its
  apparent liveness by resending a message it already sent.

**So freshness must come from `received_at`, and replay must be impossible.**
`received_at` removes the subject's control of the clock; strict per-subject
monotonicity removes its ability to re-use a message. Each closes the other's
hole, and neither does alone.

#### G7.2 The model

| Concern | Rule |
|---|---|
| `observed_at` | **Subject-authored. A claim.** Retained for audit. **Never** an input to `heartbeat-freshness`. An `observed_at` in the future beyond a declared tolerance, or diverging from `received_at` beyond a declared tolerance, is **refused** and the refusal recorded. |
| `received_at` | **Health-authored, at the receiving surface.** The **only** input to `heartbeat-freshness`. |
| Sequence | **`sequence` becomes required** (it is optional today), as `{epoch, sequence}`: `epoch` non-decreasing per subject, `sequence` strictly increasing within an epoch. |
| Monotonicity | A heartbeat whose `(epoch, sequence)` is **not strictly greater** than the last accepted pair for that subject is **refused**. |
| Replay | Caught by the monotonicity rule — a replayed pair has been seen, so it is refused and **never acquires a `received_at`**. This is the mechanism; `received_at` alone is not. |
| Duplicates | Same rule. Refused, not silently ignored: a refused claim is recorded as evidence that something resent a message. |
| Out-of-order arrival | Refused by monotonicity. A late heartbeat adds nothing a newer one has not already established. |
| Restart / reset | A restart **increments `epoch`** and may reset `sequence`. A bare `sequence` decrease within the same epoch is a replay and is refused. This is why an epoch exists rather than a single counter: without it, restart and replay are indistinguishable from the claim alone. |
| Clock skew | **Irrelevant to freshness by construction**, since freshness uses `received_at`. Skew remains visible as the recorded `observed_at`/`received_at` divergence, which is a fact about the subject worth keeping. |
| Missing sequence | Refused. The field is required. |
| Subject identity binding | **`subject_id` must be bound to an authenticated channel identity at the receiving surface, and a mismatch refused.** Taking `subject_id` from the payload alone lets any subject heartbeat on another's behalf — a reference-substitution attack with a trivially cheap payload. This is a transport/authn requirement, flagged because it cannot be satisfied by a schema. |

#### G7.3 The heartbeat-only self-certification invariant

> **INDEPENDENT-EVIDENCE INVARIANT.** A subject may reach `healthy` only if at
> least one dimension satisfied in its envelope is established by an observation
> whose `collector_id` is **not the subject itself**. Dimensions derived from the
> subject's own claims — `heartbeat-freshness` foremost — can never, alone,
> support `healthy`.

**An envelope declaring only subject-derived dimensions yields
`insufficient-policy`, not `healthy`.** That is the correct existing state and
needs no new vocabulary: an envelope that cannot distinguish "alive" from
"working" is an envelope that has not declared enough to assert health, which is
precisely what `insufficient-policy` means. It is visible, inert, and creates
pressure to finish the envelope — the same mechanism the Null Policy Rule uses,
applied to a different incompleteness.

| Field | Value |
|---|---|
| **FINDING_ID** | G7 |
| **CURRENT_ARCHITECTURE** | CHBEAT is `record_class: claim`, `confers_trust: false`, `confers_eligibility: false`, `absent_heartbeat_means: unknown-never-healthy`. ADR-0013: a heartbeat "is evidence that **something sent a message**, which is not the same as the capability working". |
| **RELEASED_RUNTIME_CONSTRAINT** | CHBEAT requires `heartbeat_id`, `subject_type`, `subject_id`, `observed_at`, `provenance`; `sequence` is **optional** with no stated rule. Searching every Health document and schema for `replay`, `idempot`, `nonce` or `monotonic` returns exactly one hit: the optional `sequence` field itself. There is no receipt timestamp. |
| **SECURITY_CONSTRAINT** | This is the attack ADR-0013 names in its own Context — "a node that wants work need only look healthy" — and the released schema has no mechanism against it. Three distinct vectors: fabricated timestamps, replayed messages, and heartbeating on another subject's behalf. |
| **COMPATIBILITY_CONSTRAINT** | None — no CHBEAT exists. Making `sequence` required now costs nothing; doing it later would be a required-field addition to a populated family. |
| **OPTIONS_CONSIDERED** | **(a)** `received_at` + required `{epoch, sequence}` + authenticated subject binding. **(b)** `received_at` only, accepting replay. **(c)** Required monotonic sequence only, accepting subject-chosen clocks. **(d)** Cryptographically signed heartbeats with a nonce. |
| **RECOMMENDED_RESOLUTION** | **(a)**, as specified in §G7.2, plus the independent-evidence invariant in §G7.3. |
| **WHY** | (b) and (c) each close one hole and leave the other, as §G7.1 shows. (d) is stronger and disproportionate for a record that **confers nothing**: a heartbeat's worth is already bounded to one dimension among several, so the defence only needs to stop it being *inflated*, not make it authoritative. (a) achieves that with one required field pair and one receipt timestamp. The independent-evidence invariant is the part that makes the whole thing safe: however well a subject manages its own heartbeats, it cannot reach `healthy` on them, so the remaining value of forging one is to avoid looking `unavailable` — which is exactly the bound ADR-0013 intends. |
| **RECORDS_AFFECTED** | None existing. Future: CHBEAT, CHSTATE. |
| **SCHEMAS_AFFECTED** | `capability-heartbeat`: add `received_at` (required, Health-authored), promote `sequence` to required as `{epoch, sequence}`, add the divergence-tolerance and monotonicity rules. `capability-health-state`: the independent-evidence invariant. |
| **ADRS_AFFECTED** | **ADR-0013** — the heartbeat trust model and the independent-evidence invariant. |
| **DOCS_AFFECTED** | `observation-model.md` ("Heartbeats are claims"), `health-states.md` (what `healthy` requires). |
| **RUNTIME_SURFACES_AFFECTED** | Future: the heartbeat receiving surface, CHSTATE derivation, and the authenticated transport binding. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** A replayed `(epoch, sequence)` is **refused** and does not refresh liveness; a `sequence` decrease within an epoch is refused; an epoch increment is accepted; a future `observed_at` beyond tolerance is refused; a missing `sequence` is refused; `heartbeat-freshness` is computed only from `received_at`, asserted by varying `observed_at` and showing the result does not move; a `subject_id` not matching the channel identity is refused; and **an envelope declaring only `heartbeat-freshness` yields `insufficient-policy`, never `healthy`**. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G8 — Health store root and authority boundary

| Field | Value |
|---|---|
| **FINDING_ID** | G8 |
| **CURRENT_ARCHITECTURE** | No Health store location is declared anywhere in ADR-0013, `docs/health/` or the six schemas. |
| **RELEASED_RUNTIME_CONSTRAINT** | The three existing stores are `/var/lib/kyri/fabric`, `/var/lib/kyri/trust` and `/data/kyri/capability-runtime`, each `cschott:cschott 0700` with records at `0600`; approved operator inputs live separately at `/etc/kyri/fabric`, `root:cschott 0750`. `DIR_MODE = 0o700` / `FILE_MODE = 0o600` are the established constants. Sequence allocation is a per-kind `.seq` file under a `sequences/` directory, written under `flock` with `fsync`, refusing rollover rather than reusing a name. |
| **SECURITY_CONSTRAINT** | **The reason this is architecture and not deployment trivia.** If Health records lived inside the Fabric store, the Health writer would hold write access to the Fabric store, and invariant 16 — "Health cannot mutate Trust or Fabric state" — would rest on application-level discipline rather than filesystem authority. Filesystem authority survives a bug; discipline does not. The same argument applies in reverse: the Fabric must hold **no** write path to the Health store, or a Fabric defect could manufacture the evidence that removes its own candidates. |
| **COMPATIBILITY_CONSTRAINT** | None, provided no existing store root is reused or re-permissioned. |
| **OPTIONS_CONSIDERED** | **(a)** `/var/lib/kyri/health`, a separate store beside Fabric and Trust. **(b)** A subtree of the Fabric store — **rejected** on the security constraint. **(c)** `/data/kyri/capability-health`, beside the capability runtime. |
| **RECOMMENDED_RESOLUTION** | **(a) `/var/lib/kyri/health`.** Owner `cschott:cschott`, directories `0700`, records `0600`, matching the Fabric and Trust precedent exactly. Six record directories — `capability-health-envelopes`, `capability-heartbeats`, `capability-health-observations`, `capability-health-states`, `capability-degradation-events`, `capability-health-recommendations` — plus `sequences/` holding six `.seq` files, allocated through the released `flock` + `fsync` read-modify-write with no rollover. Widths: `CHENV` 4, the other five 6. **Authority directions, stated as a matrix rather than prose:** Health **writes** only its own store; Health **reads** Fabric and Trust **only** through read-only adapters and never by direct record access; the Fabric **reads** Health only through the `health_adapter`; the Fabric **never writes** Health; Trust **neither reads nor writes** Health, which is ADR-0011's directionality rule at the filesystem layer. Human-authored envelope inputs follow the `/etc/kyri/fabric` precedent — a separate `root:cschott 0750` approved-input directory — so that authoring a threshold and running the evaluator are not the same authority. |
| **WHY** | It reuses every released pattern — location convention, ownership, modes, sequence allocation — so nothing new has to be designed or defended, and it puts the one invariant that matters most under filesystem control rather than code review. Option (c) is equally safe and gratuitously different; `/var/lib/kyri/` already holds the two governance stores and Health is a governance store. |
| **RECORDS_AFFECTED** | None. |
| **SCHEMAS_AFFECTED** | None required. |
| **ADRS_AFFECTED** | **ADR-0013** — a deployment and authority-boundary statement. |
| **DOCS_AFFECTED** | `governance-boundaries.md`, which states the consume/cannot-change asymmetry and can now name the mechanism enforcing it. |
| **RUNTIME_SURFACES_AFFECTED** | Future: the Health store, sequence allocation, both adapters. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** Assert the declared root in ADR-0013, the store implementation and the provisioning documentation agree; assert the Health package holds no write path to the Fabric or Trust roots, by module and by path, the way `tests/test-capability-runtime.sh` already asserts the reverse direction; assert the Fabric holds no write path to the Health root. **No directory is created in this increment.** |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G9 — collector identity and contradictory sources

| Field | Value |
|---|---|
| **FINDING_ID** | G9 |
| **CURRENT_ARCHITECTURE** | CHOBS requires `source` — "The named source that produced it. A measurement with no source cannot be weighed against a contradicting one." |
| **RELEASED_RUNTIME_CONSTRAINT** | `source` is **free text** with no `source_type`, no identity constraint, no authentication and no integrity binding, so a forged CHOBS naming any source is schema-valid. **And the platform already has the mechanism it needs:** `platform-model/schemas/observation.schema.yaml` requires **`collector_id`** *and* **`source_fingerprint`**; `tools/collectors/registry.py` implements a `CollectorRegistry` whose `get()` **refuses** an unregistered id — `"collector id '…' is not registered"` — with `ids()` and `list_manifests()` enumerating the closed set. No conflict-resolution rule between sources exists anywhere, so the field's stated purpose is unmet even when populated honestly. |
| **SECURITY_CONSTRAINT** | Collector compromise must not become authoritative Health truth. Two sub-requirements: an observation must be attributable to a **governed** identity, not a self-chosen string; and a compromised collector contradicting an honest one must not win by default. Note which way the danger runs — a forged **good**-health observation is the more valuable attack, because `healthy` is the only state supporting a positive claim, while a forged bad one can at most remove a candidate the route order would have replaced anyway. |
| **COMPATIBILITY_CONSTRAINT** | None — no CHOBS exists. |
| **OPTIONS_CONSIDERED** | Identity: **(a)** reuse `collector_id` from the existing registry, as `observation` already does; **(b)** a new Health-specific collector entity type; **(c)** model collectors as capability instances; **(d)** keep free text. Contradiction: **(w)** newest wins; **(x)** declared source precedence; **(y)** trusted-source precedence; **(z)** contradiction yields `unknown` with both cited and review required. |
| **RECOMMENDED_RESOLUTION** | **(a) + (z).** Replace CHOBS's free-text `source` with **`collector_id`**, constrained to the existing closed `CollectorRegistry`, and add **`source_fingerprint`**, exactly as `observation.schema.yaml` already requires both. An unregistered `collector_id` is **refused**. For contradictions: two or more **fresh** observations of the **same dimension** for the **same subject** from **different** `collector_id`s whose values disagree about the declared condition yield **`unknown`** for that dimension, **citing every contradicting observation**, with `review_required: true`. By `worst-dimension-wins`, an `unknown` dimension prevents `healthy` and — being `unknown` — contributes **no subtraction**. |
| **WHY** | On identity, the reviewer asked to avoid a parallel identity system, and the platform already has the governed one: `collector_id` is required on `observation`, backed by a registry that refuses unregistered ids, with `source_fingerprint` for integrity. Reusing it is strictly less new machinery than any alternative and inherits an enforcement path that already exists. (b) duplicates it; (c) is wrong in kind — a collector is not a capability and modelling it as one would make it routable; (d) is the gap. On contradiction, (z) is the only option that preserves the layer's defining property in **both** directions: uncertainty becomes neither a positive claim nor positive evidence for removal. (w) lets a compromised collector win simply by writing last, which is the cheapest possible attack. (x) and (y) both require a precedence policy nobody has authored, and (y) in particular would make Health read Trust standing for collectors as an input to a health verdict — a trust-shaped decision inside the observability layer, which is the direction ADR-0011 exists to keep closed. The cost of (z) is honest: one compromised collector can force a dimension to `unknown` and so prevent `healthy`. That is a denial of *reassurance*, not a denial of service — it removes no candidate — and it is the correct trade, because the alternative is letting a forged observation establish health. |
| **RECORDS_AFFECTED** | None existing. Future: CHOBS. |
| **SCHEMAS_AFFECTED** | `capability-health-observation`: `source` → `collector_id`, plus `source_fingerprint`; a contradiction rule. `capability-health-state`: contradiction yields `unknown` with `review_required`. |
| **ADRS_AFFECTED** | **ADR-0013** — collector identity and the contradiction rule. |
| **DOCS_AFFECTED** | `observation-model.md`, which promises weighing and defines none. |
| **RUNTIME_SURFACES_AFFECTED** | Future: the CHOBS write path, registry validation, derivation. Reuses `tools/collectors/registry.py`. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** Assert an unregistered `collector_id` is refused; assert the registry's `ids()`, the schema constraint and the ADR agree; assert two contradicting fresh observations yield `unknown` with **both** cited and `review_required: true`; assert that result is **not** `healthy` and produces **no subtraction**; assert a single compromised collector cannot establish `healthy` alone (with G7's independent-evidence invariant). |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G10 — `review_required` on CHSTATE

| Field | Value |
|---|---|
| **FINDING_ID** | G10 |
| **CURRENT_ARCHITECTURE** | `observation-model.md`: "The **Null Policy Rule** is **inherited exactly**." The Confidence and Freshness Standard's conformance list: "a null freshness policy produces `unknown` **with `review_required: true`**, never a default maximum age." |
| **RELEASED_RUNTIME_CONSTRAINT** | CHSTATE requires `freshness` and `reason` but **not** `review_required`. Of the six Health schemas only CHREC carries it. The envelope permits `freshness_policy_seconds: null` explicitly. |
| **SECURITY_CONSTRAINT** | Low, and real. The flag is the pressure mechanism: without it, an `unknown` arising from an undeclared policy is indistinguishable in the record from an `unknown` arising from a collection failure, so the gap that needs *configuring* looks like the gap that needs *fixing*. Misdirected remediation leaves the undeclared policy in place indefinitely. |
| **COMPATIBILITY_CONSTRAINT** | None. |
| **OPTIONS_CONSIDERED** | **(a)** Always required on CHSTATE, boolean. **(b)** Conditionally required — present and `true` whenever any dimension's `freshness_policy_seconds` is null, or the state is `insufficient-policy`, or a source contradiction occurred (G9). **(c)** Derive it at read time without storing, from the cited envelope version. |
| **RECOMMENDED_RESOLUTION** | **(b).** `review_required` present and `true` whenever the state arises from a null freshness policy, from `insufficient-policy`, or from a G9 contradiction; present and `false` otherwise. Pair it with the existing required written `reason`, which must name **which** gap — undeclared policy, missing envelope, or contradicting sources — since "review required" without a subject is an alert, not a finding. |
| **WHY** | (b) satisfies "inherited exactly" — the standard conditions the flag on the null policy, so unconditional truth would over-report and unconditional absence under-reports. (c) looks attractive because the envelope is cited and the derivation is cheap, and it fails on the architecture's own terms: the envelope is **superseded, never edited**, and a later version may declare the policy that was null, so a read-time derivation would retroactively clear `review_required` on a past assessment — which is precisely the "supersession never rewrites prior evaluations" rule. The flag must be a stored fact about what was true at `evaluated_at`. (a) is simpler and loses the signal in noise. |
| **RECORDS_AFFECTED** | None existing. Future: CHSTATE. |
| **SCHEMAS_AFFECTED** | `capability-health-state` — `review_required`, conditionally required. |
| **ADRS_AFFECTED** | **None.** The standard already requires it; only the schema omits it. |
| **DOCS_AFFECTED** | `unknown-and-freshness.md`, `health-states.md` — the flag as part of what a state must carry. |
| **RUNTIME_SURFACES_AFFECTED** | Future: derivation. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** Assert the Confidence and Freshness Standard's conformance list, the CHSTATE schema and the derivation agree; assert a null freshness policy yields `unknown` **with** `review_required: true`; assert `insufficient-policy` carries it; assert a later envelope version does **not** clear it on a prior state. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G11 — route-level degraded policy

| Field | Value |
|---|---|
| **FINDING_ID** | G11 |
| **CURRENT_ARCHITECTURE** | `health-states.md` state table: `degraded` → "May remove, **per route policy**, on fresh evidence", against `unavailable` → "**Removes**, on fresh evidence". ADR-0013 principle 4: "Health removes eligibility only on fresh positive evidence of **an ineligible condition**." |
| **RELEASED_RUNTIME_CONSTRAINT** | **There is no per-route health policy, and the route schema's health rules are deliberately uniform.** `capability-route.schema.yaml` declares `health_may_remove: true`, `health_may_reorder: false`, `health_may_add: false`, `absent_health_means: unknown-never-healthy`, `automatic_rerouting: forbidden` — as **schema-level invariants of the route kind**, not as fields on a route record. Neither `required_fields` nor `optional_fields` contains any health policy field. `forbidden_behaviours` bars `adaptive-placement`, `latency-optimization` and `automatic-failover`; `forbidden_fields` bars `health_score`, `auto_reorder` and `predicted_availability`. `select_candidate` applies `health_removals` uniformly with no per-route modulation. |
| **SECURITY_CONSTRAINT** | Per-route health policy is a per-route exemption surface, and the schema's own comment on effect classes warns about exactly this shape: "No route may lift the prohibition — a restriction that can be lifted per-route is one that gets lifted during an incident." A route-level knob controlling whether health may remove would be adjustable under pressure, by whoever is on call, with no trust decision recorded. |
| **COMPATIBILITY_CONSTRAINT** | Adding a **required** route field would affect `CROUTE-0001`…`CROUTE-0007`; an optional one would not. Option C requires **no** route change at all. |
| **OPTIONS_CONSIDERED** | **(A)** Add an explicit route-level health policy field. **(B)** Fresh `degraded` is uniformly subtractive. **(C)** `degraded` is inert in v1; subtraction reserved for fresh `unavailable`. **(D)** A platform-wide declared policy outside the route, one setting for all routes. |
| **RECOMMENDED_RESOLUTION** | **(C) for ENG-0006 v1**, with **(A)** named as the declared future path if operators later want selective subtraction. Fresh `unavailable` subtracts. Fresh `degraded` is **inert on eligibility**, fully disclosed under G1 with a required warning, and is the primary trigger for a CHREC. |
| **WHY** | **(C) is the faithful reading of the accepted architecture, not a simplification of it** — which matters, because the brief forbids reinterpreting Health architecture to make implementation easier. `health-states.md` conditions degraded-removal on a route policy. No route policy exists. The stated condition is therefore unsatisfied, and a layer that "removes only on fresh positive evidence of an ineligible condition" removes nothing when the condition for removal has no referent. Making it subtract uniformly (B) would **grant** degraded a power the sentence conditioned, which is the larger reinterpretation. Two substantive arguments reinforce it. First, `degraded` means "outside the envelope on at least one dimension, **still responding**" — a *working* capability outside a hand-authored limit, and ADR-0013's own Accepted Consequences say "Declared thresholds may initially be imperfect… a guess until real traffic exists". Removing working capacity on a first-draft guess is a worse failure than leaving it in with a conspicuous warning, and it is the failure the operator cannot see, because the route silently narrows. Second, with `MAXIMUM_SLOTS` capacity and declared candidate order, uniform degraded-subtraction means one over-tight threshold can empty a route and turn a thresholds-wrong problem into an outage — `automatic_rerouting: forbidden` means nothing catches it. **(A)** is rejected for v1 on the per-route-exemption argument above, and because adding route complexity "because prose once mentioned it" is what the brief warns against; it stays available additively, and if adopted it should be a declared enum rather than a boolean. **(D)** is a reasonable second choice and still adds a policy surface before any traffic has shown it is needed. |
| **RECORDS_AFFECTED** | **None** under (C). Under (A), new `capability-route` records only. |
| **SCHEMAS_AFFECTED** | **None** under (C). |
| **ADRS_AFFECTED** | **ADR-0013** — state the v1 subtraction rule plainly: `unavailable` subtracts, `degraded` discloses and recommends. |
| **DOCS_AFFECTED** | `health-states.md` — the "per route policy" clause must be corrected to say that no route policy exists and `degraded` is therefore inert in v1, with (A) named as the future path. Leaving the phrase in place would keep a normative document pointing at a referent that does not exist. |
| **RUNTIME_SURFACES_AFFECTED** | Future: the `health_adapter`'s subtraction rule; `health_removals` population. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None** under (C). Seven existing routes untouched. |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** Assert ADR-0013, `health-states.md`, the route schema's health invariants and the adapter agree on exactly which states subtract; assert fresh `degraded` produces **no subtraction** and a disclosed warning; assert fresh `unavailable` subtracts; assert no route record carries a health policy field in v1; assert the route's `health_may_reorder: false` and `health_may_add: false` remain true of the adapter. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G12 — CRES outcomes as Health evidence

| Field | Value |
|---|---|
| **FINDING_ID** | G12 |
| **CURRENT_ARCHITECTURE** | ADR-0013 names "execution outcomes" among the signals that stay individually explainable. CHOBS has `success-count` and `failure-count`, "outcomes over a declared window". |
| **RELEASED_RUNTIME_CONSTRAINT** | `tools/capability/records.py:101` — `OUTCOME_CLASSES = ("completed", "refused", "adapter-error", "provider-error", "timeout", "cancelled", "interrupted", "serialisation-failure")`. **Eight values, two more than the brief enumerates** (`timeout` and `serialisation-failure`). CRES also carries `started_at`, `ended_at`, `attempt_number` and `invocation_record_id`, so latency is derivable. The boundary is enforced: the Capability Runtime is "architecturally barred from the health and orchestration plane", with `tests/test-capability-runtime.sh:143-145` forbidding `tools.health`, `..health`, `liveness`, `readiness` and `heartbeat` **by name**, and `quarantine.py` stating quarantined output "cannot reach Fabric, Trust, or Health". |
| **SECURITY_CONSTRAINT** | The direction must stay one-way: a Health-side collector **reads** CRES; the Capability Runtime **never pushes**. A push path would give the executing plane a write into the plane that can remove its candidates. And the mapping itself is a security question: counting governed refusals as failures would make correct fail-closed behaviour read as degradation, so an attacker who can provoke refusals could manufacture a health finding. |
| **COMPATIBILITY_CONSTRAINT** | Read-only over existing CRES records. `CRES-000001` and `CRES-000002` are unchanged and unread-for-mutation. |
| **OPTIONS_CONSIDERED** | Mapping: **(a)** three-way — success / failure / neither; **(b)** two-way, every non-`completed` is a failure; **(c)** a new `execution-outcome` dimension carrying the class. Dimension set: **(i)** keep `success-count`/`failure-count` only; **(ii)** add `execution-refusal-count`; **(iii)** add a `latency` source from CRES instants. |
| **RECOMMENDED_RESOLUTION** | **(a) + (i)**, with the three-way mapping below. **`refused` is neither a success nor a failure** and is excluded from both counters. |

| `outcome_class` | Maps to | Why |
|---|---|---|
| `completed` | **success** | The capability did the work. |
| `refused` | **neither** | A governed refusal is the platform working correctly. Counting it as failure would make fail-closed behaviour look like degradation. |
| `provider-error` | **failure** | The thing being executed failed. |
| `adapter-error` | **failure** | The execution path failed; attributable to the subject's adapter. |
| `timeout` | **failure** | No result within the declared bound. |
| `interrupted` | **failure** | Execution did not reach a result. |
| `cancelled` | **neither** | An external decision stopped the work. It says nothing about the subject. |
| `serialisation-failure` | **failure** | A result was produced and could not be recorded; attributable to the execution path. |

| Field | Value |
|---|---|
| **WHY** | The brief is explicit that not every non-`completed` outcome is capability failure, and the vocabulary bears that out twice: `refused` is the Capability Runtime's correct answer to an ungoverned request, and `cancelled` is somebody else's decision. Option (b) would make both read as subject faults, inverting the collection-failure principle — a refusal is the platform concluding correctly, much as a failed collection is the collector concluding nothing. Three buckets with an explicit **neither** are the smallest structure that keeps that honest, and `success-count`/`failure-count` need no change: observations are already per-dimension counts over a declared window, and `windowed_count` (G3) evaluates them. Option (ii) is tempting — refusal volume is operationally interesting — and is rejected for v1 because a refusal-rate dimension has no defensible envelope: a high refusal rate may mean a misconfigured caller, a correct policy, or an attack, and `insufficient-policy` is the honest state for a dimension whose threshold nobody can justify. ADR-0013's rule that a dimension must stay individually explainable is the test, and this one is not. Option (iii) — deriving `latency` from `started_at`/`ended_at` — is **defensible and recommended as a separate later increment**, because it needs its own decision about whether adapter overhead belongs in the number. |
| **RECORDS_AFFECTED** | None. CRES is read-only. |
| **SCHEMAS_AFFECTED** | **None.** `success-count`/`failure-count` suffice. |
| **ADRS_AFFECTED** | **ADR-0013** — the mapping table, so it is normative rather than a collector's private choice. |
| **DOCS_AFFECTED** | `observation-model.md` — name CRES as a source for the two counters and state the one-way direction. |
| **RUNTIME_SURFACES_AFFECTED** | Future: a Health-side CRES collector. **No Capability Runtime change, and the barrier test must keep passing unaltered.** |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** Read-only. |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** Assert the mapping table in ADR-0013, the collector and `OUTCOME_CLASSES` cover **all eight** values with no unmapped class; assert `refused` and `cancelled` increment **neither** counter; assert the Capability Runtime still imports nothing from Health (the existing named-module assertion, unchanged); assert no Health module is importable from the Capability Runtime package. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

### G13 — subject binding and referential identity

| Field | Value |
|---|---|
| **FINDING_ID** | G13 |
| **CURRENT_ARCHITECTURE** | `subject_type` and `subject_id` are required on all six families. `OBSERVES_HEALTH_OF`, `HEALTH_STATE_OF` and `RECOMMENDS_ACTION` constrain targets to `capability-instance`, `capability-host`, `capability-package`. |
| **RELEASED_RUNTIME_CONSTRAINT** | **No rule requires a CHSTATE's subject to match the subject of the observations it cites.** A state citing another subject's observations is schema-valid: the identifiers are well-formed, the types are permitted, and nothing compares them. The same hole exists for CHDEG and CHREC. |
| **SECURITY_CONSTRAINT** | This is the subject-substitution attack, and it is the cheapest route to a forged positive claim: cite a healthy subject's observations on a broken subject's state and the broken subject reads `healthy` with real, verifiable, correctly-signed evidence behind it. Every individual record passes inspection; only the **relationship** between them is false. ID-format validation cannot see it. |
| **COMPATIBILITY_CONSTRAINT** | None. |
| **OPTIONS_CONSIDERED** | **(a)** Schema-declared rule only. **(b)** Ontology relationship validation only. **(c)** Runtime semantic validation only. **(d)** All three, layered. |
| **RECOMMENDED_RESOLUTION** | **(d)**, with each layer doing what only it can. **Schema** — declare the binding requirement on CHSTATE, CHDEG and CHREC as a named constraint, so the requirement is discoverable where the record is defined, and declare that identifier format is **not** sufficient. **Ontology** — the G2 edges `DERIVED_FROM_OBSERVATIONS` and `FOLLOWS_FROM_STATE` carry a same-subject requirement, so a relationship-validation pass can reject a cross-subject citation without reading the Health runtime. **Runtime** — the binding is **enforced at write time** and the record **refused**, because this is the only layer that can resolve the references and compare them. Specific rules: every CHSTATE's `(subject_type, subject_id)` equals that of **every** cited CHOBS; every CHDEG's equals that of every cited CHOBS and of the states it transitions between; every CHREC's equals that of its cited CHSTATE and, where present, CHDEG; a cited CHENV's `(subject_type, subject_id)` equals the state's; a reference to a non-existent CHOBS, CHENV, CHSTATE or CHDEG is **refused**, not skipped; and a refusal names the mismatch class from a closed vocabulary without echoing values. |
| **WHY** | Layering is not belt-and-braces here, because the three layers see different things. The schema is where an implementer looks and cannot enforce a cross-record fact. The ontology can express the constraint declaratively and cannot resolve references. Only the runtime can read both records and compare, and it is the only layer that can **refuse a write** — which is the sole point at which a malformed citation can be stopped before it becomes evidence. Any single layer leaves the attack open: (a) documents it, (b) catches it only if a validation pass is run, (c) enforces it but leaves it invisible where the record is defined. The brief's instruction not to rely on ID format alone is exactly this: the identifiers in a substitution attack are all valid. |
| **RECORDS_AFFECTED** | None existing. Future: CHSTATE, CHDEG, CHREC. |
| **SCHEMAS_AFFECTED** | `capability-health-state`, `capability-degradation-event`, `capability-health-recommendation` — a declared subject-binding constraint. |
| **ADRS_AFFECTED** | **ADR-0013** — a short referential-integrity statement; its audit section assumes this and never says it. |
| **DOCS_AFFECTED** | `observation-model.md`, `governance-boundaries.md` (audit requirements). |
| **RUNTIME_SURFACES_AFFECTED** | Future: validation for all three derived families; relationship validation. |
| **EXISTING_PRODUCTION_RECORD_IMPACT** | **None.** |
| **MIGRATION_REQUIRED** | **No.** |
| **CROSS_ARTIFACT_TEST_REQUIRED** | **Yes.** Assert a CHSTATE citing another subject's CHOBS is **refused**; same for CHDEG and CHREC; assert a CHENV for a different subject is refused; assert a non-existent reference is refused rather than skipped; assert the refusal names a mismatch class and echoes no value; assert the schema constraint, the ontology edge requirement and the runtime rule agree. |
| **REVIEWER_DECISION_REQUIRED** | **PENDING** |

---

## 4. Additional review questions

### A — first evaluation, and whether CHDEG is still the right name

**A1. Is the first ever CHSTATE for a subject a transition? Recommendation: no,
and it emits no CHDEG.**

`health-states.md` says "Every transition **between** health states produces a
degradation event, including recovery." A transition between states requires a
prior state, and the first evaluation has none: `unknown` is declared as the
**default** — "No fresh observation exists" — not as a recorded state a subject
was previously in. So emitting nothing on first evaluation is a **clarification
of the existing rule, not a narrowing of it**, which matters because the brief
forbids reinterpreting the architecture for convenience.

The operational argument points the same way. Under the literal reading, every
subject ever added produces a *degradation event* the first time it is evaluated
— alert volume at precisely the moment nothing is wrong, which is the flapping
failure `degradation-semantics.md` exists to prevent, arriving through a
different door. And `hysteresis` could not be satisfied on a first evaluation
anyway: there is no prior span over which a condition held, so by the
architecture's own rule — "A transition that cannot show its hysteresis was
satisfied is not recordable" — the event is **not recordable**. The two rules
already agree; only the prose is ambiguous.

Proposed rule: a CHSTATE with no predecessor for its subject is an **initial
state**, carries `supersedes: null`, and produces **no CHDEG**. Every subsequent
change of `state` value produces exactly one CHDEG. A re-derivation producing the
**same** state value is a new CHSTATE (append-only) and produces **no** CHDEG,
since nothing transitioned.

**A2. Is `capability-degradation-event` still the right name?
Recommendation: keep it for v1. Do not rename.**

The record intentionally represents **all** transitions, and the enums bear that
out: both `from_state` and `to_state` admit all seven values, so
`unknown → healthy`, `degraded → healthy` and `unknown → unmonitored` are all
representable. The name does fight the content, and the architecture already
knows it: `degradation-semantics.md` states plainly that "**Recovery is a
transition too**", so the name was already being used for non-degradations by
deliberate choice rather than oversight.

Against renaming: `CHDEG` is a declared `id_prefix` in `entity-types.yaml`, an
`id_pattern` in the schema, one of the six accepted families named in ADR-0013
and the roadmap, and a reserved name reconciled from the v0.9.6 reservation
(`degradation-event` → `capability-degradation-event`). Renaming touches all of
those to fix a readability complaint, and the brief says not to rename anything
yet. **If** the reviewer ever wants it, the honest name is
`capability-health-transition` (`CHTRAN`), and it should be done as a deliberate
identifier change with the old name recorded as superseded — not quietly.

Smallest improvement available now without a rename: state in ADR-0013 and
`degradation-semantics.md` that the record is **the health-state transition
record**, that `degradation` in its name is historical, and that a transition
toward `healthy` is recorded by the same family. That is a comment-level
correction and it removes the trap for the next implementer.

### B — package subjects and the dimension matrix

**Recommendation: yes, the subject/dimension matrix needs an explicit
constraint**, and it should be declared on the CHOBS schema rather than left to a
collector's judgement.

`CHBEAT` already gets this right by excluding `capability-package` — a package is
not a running thing and has no liveness. `CHOBS` admits `capability-package` for
**every** dimension including `availability`, `latency`, `queue-depth` and all
five resource-pressure dimensions, none of which a non-running artifact can have.
An `availability` observation about a package is a claim about something that does
not run.

Proposed matrix:

| Dimension group | Dimensions | Valid subjects |
|---|---|---|
| Liveness | `availability`, `heartbeat-freshness`, `transport-health` | **instance, host** |
| Performance | `latency`, `queue-depth`, `success-count`, `failure-count` | **instance, host** |
| Resource pressure | `cpu-`, `memory-`, `gpu-`, `vram-utilization`, `storage-pressure` | **host**, and instance where the host attributes usage to it |
| Observability | `collector-freshness` | **any subject** — it is a fact about the collector, not the subject |

**That leaves `capability-package` with no declarable runtime dimension**, which
forces a reviewer decision rather than one I should make silently:

- **(a) Remove `capability-package` from the CHOBS subject enum**, on ADR-0013's
  own argument for dropping `lease-health` and `placement-health`: shipping a
  subject whose observations cannot exist creates "schemas whose subjects do not
  exist, which is the specification equivalent of a dangling reference." A package
  would then simply have no health, as an endpoint has none — its health is the
  health of the instances running it.
- **(b) Keep it** and accept that a package is permanently `unmonitored`, since no
  envelope can declare a valid dimension for it.

**Recommended: (a)**, consistently applied — if a package cannot be observed, it
should not be a subject of CHOBS, and whether it remains a subject of CHENV,
CHSTATE, CHDEG and CHREC should be decided in the same pass rather than left
asymmetric. `REVIEWER_DECISION_REQUIRED: PENDING`.

### C — the `health_adapter` contract

**Structural properties, borrowed from `trust_adapter.py`** — these the reviewer
accepted: read-only; owns no policy and no verdict of its own; the caller
supplies the evaluation instant, because "an adapter that read the time would
answer a question nobody asked"; refusals drawn from a closed controlled
vocabulary so no path, value or exception detail reaches a record; no mutation;
no hidden memory, no stored verdict, no retry.

**Failure semantics, which differ and must not be copied.** Trust fails closed by
**denying authority**. Health has no authority to deny, so it fails closed on the
**claim**:

| Adapter input | Health contribution | Disclosure |
|---|---|---|
| **Valid, current, positive removal evidence** — fresh `unavailable`; fresh `degraded` only if G11(A) is ever adopted | **May contribute a removal** | `health_effect: removed`, state, freshness, envelope version |
| **`unknown` / stale / `withheld` / `insufficient-policy` / `unmonitored`** | **No Health subtraction** | `health_effect: none`, **warning required** |
| **Malformed / unreadable / unverifiable / unavailable Health store** | **No Health subtraction** | `health_effect: none`, **warning required**, plus `adapter_outcome` and `evidence_unusable_reason` from closed vocabularies |
| **`healthy`, however fresh** | **No addition to eligibility.** Health never adds | `health_effect: none`, no warning required |

**The wording rule, restated because this table is where it will be misread.**
"No Health subtraction" means **only** that Health did not remove the candidate.
It is **not** a statement that the candidate is eligible. Eligibility is decided
by the twelve `ELIG` conditions, quarantine at `ELIG-10`, `availability_intent`,
restricted scope, revocation and the declared route — every one of which runs
independently, and all of which ran **before** Health was consulted, since
`selection.py:370` applies health after `evaluate_eligibility`. A candidate Health
did not remove may be ineligible for any of them.

**One asymmetry worth stating explicitly**, because it is the inverse of the trust
adapter and an implementer copying `trust_adapter.py` would get it backwards:
`trust_adapter` resolves absent, expired, revoked, malformed, unreadable **and**
unavailable all to one answer, `unverified`, and `unverified` **removes**
eligibility. The health adapter resolves the same six conditions to one answer
too — but that answer is **no subtraction**, the opposite effect. Same structure,
inverted consequence. A test should assert this by name.

---

## 5. Compatibility inventory

**Mandatory requirement: no ENG-0006 resolution may require rewriting an existing
immutable production record. EXISTING_RECORD_REWRITE_REQUIRED = NO.**

| Record family | Count in production | Impact | Mechanism |
|---|---|---|---|
| **`capability-selection`** | 5 — `CSEL-000001`…`CSEL-000005` | **None.** Remain byte-identical, remain loadable, read as pre-disclosure records | G1: new defaulted fields + closed later-member declaration + write-time enforcement. `from_dict` refuses unknown keys and never checks for missing ones, so an added field cannot invalidate an older record |
| **`capability-route`** | 7 — `CROUTE-0001`…`CROUTE-0007` | **None** under the recommended G11(C) | No route schema change in v1 |
| **`capability-instance`** | 7 | **None** | Health reads instances; it never writes them |
| **`capability-advertisement`** | 8 | **None** | Not referenced by Health |
| **`capability-host` / `-package` / `-contract` / `-definition`** | 1 each | **None** | Subjects of observation only |
| **`capability-invocation` (CINV)** | 3 | **None** | Read-only; the CRES collector reads results, not invocations |
| **`capability-result` (CRES)** | 2 | **None.** Read-only | G12: Health-side collector reads; the Capability Runtime never pushes |
| **Trust records** | — | **None.** Neither read as health evidence nor written | ADR-0011 directionality; G2's dedicated edges admit no trust type |
| **`CADM` / `CMUT`** | 7 / 12 | **None** | Outside Health entirely |
| **Health records** | **0** | n/a | No Health store exists |

**The one global constraint that shaped G1:** the Fabric's `schema_version` is a
single value, `"schott-platform/v1"`, shared by all eight families and enforced by
equality at `models.py:296`. Any resolution that moved it would invalidate every
Fabric record in production. **No recommended resolution moves it.**

**Forward-only version boundary, where a new required field is introduced into a
released family:** only `capability-selection` is affected (G1). Old records
remain valid under the shape that created them, are never rewritten, and are
never assigned a default meaning — a pre-disclosure record reads as
*pre-disclosure*, not as `consulted: false`.

---

## 6. Cross-artifact agreement tests

**Designed here, implemented only after the underlying decision is approved.**
These exist to prevent a recurrence of the ENG-0005 **F4** class, which this very
package has a live example of: `tests/test-capability-health.sh` asserts
`len(health_states) == 7` from the schema, passes 461 assertions, and never
compares the schema to ADR-0013 — which is why C1 survived a green suite.

**The discipline that makes a test count as cross-artifact:** it must extract the
same fact from **two or more independently authored artefacts** and compare them.
A test that reads one artefact twice, or that reads the artefact the
implementation was generated from, proves nothing about agreement.

| ID | Fact | Artefacts that must agree | Gates |
|---|---|---|---|
| **T1** | health-state vocabulary | ADR-0013 table · `health-states.md` table · CHSTATE `state` enum · CHDEG `from_state` · CHDEG `to_state` | C1 |
| **T2** | recommendation vocabulary | ADR-0013 · `governance-boundaries.md` · CHREC enum — **plus** `drain` permitted nowhere | C2 |
| **T3** | `withheld` semantics | ADR-0013 row · `health-states.md` · CHSTATE `withheld_semantics` (all eight properties) | C3 |
| **T3b** | `withheld` authority | ADR-0013 · CHENV `publication` block · derivation — and no path from `availability_intent` | G6 |
| **T4** | condition operators, units, aggregations | grammar ADR · CHENV schema · evaluator · `worked-examples.md` | G3 |
| **T5** | hysteresis forms and their proof fields | grammar ADR · CHENV schema · CHDEG required fields | G4 |
| **T6** | relationship source/target rules | ontology catalog · the six schemas' `derived_from_*` fields — **and no Trust↔Health edge in either direction** | G2 |
| **T7** | CSEL health disclosure | `selection-visibility.md` · CSEL schema · record builder · the five existing records still loading as pre-disclosure | G1 |
| **T8** | freshness at evaluation vs at selection | ADR-0013 · `unknown-and-freshness.md` · CHSTATE schema · adapter recomputation | G5 |
| **T9** | subtraction rule by state | ADR-0013 · `health-states.md` · route schema health invariants · adapter | G11 |
| **T10** | subject-binding rules | the three schemas' constraints · ontology edge requirements · runtime validation | G13 |
| **T11** | CRES outcome mapping | ADR-0013 mapping table · collector · `OUTCOME_CLASSES` — all **eight** mapped, none unmapped | G12 |
| **T12** | collector identity | `CollectorRegistry.ids()` · CHOBS schema constraint · ADR-0013 | G9 |
| **T13** | Null Policy Rule inheritance | Confidence and Freshness Standard conformance list · CHSTATE schema · derivation | G10 |
| **T14** | store boundary | ADR-0013 declared root · store implementation · provisioning docs — and no Health→Fabric/Trust write path by module or path | G8 |

**Negative-surface assertions, carried forward from ENG-0006-A §K** and
independent of any pending decision: no health score in any spelling; no
prediction or forecast field; no learned, auto, baseline or derived threshold; no
execution surface on CHREC; no write path from Health to Trust or Fabric; and the
existing `tests/test-capability-runtime.sh:143-145` barrier assertions continuing
to pass unaltered.

**Wording assertions**, because the misreading is the risk: no test name, fixture
name or message in the future Health suites may contain "malformed health ⇒
eligible", "health failure makes the candidate eligible" or "no health evidence ⇒
pass". The permitted phrasing is **"no Health subtraction"**.

---

## 7. Reviewer decision matrix

| Finding | Recommendation | Risk | Compatibility | Reviewer decision |
|---|---|---|---|---|
| **C1** | Seven states; correct ADR-0013 line 153 and its table | Low — documentation catches up to schemas | No impact | **PENDING** |
| **C2** | Four closed kinds; `consider-manual-drain`, never `drain` | Low | No impact | **PENDING** |
| **C3** | `withheld` = conclusions not asserted or published; inert | Low | No impact | **PENDING** |
| **G1** | Selection-level context + per-candidate results; defaulted fields + closed later-member set + write-time enforcement; `schema_version` unchanged | **Medium-high** — touches a released ADR-0012 record | **5 CSEL records unchanged, unrewritten, not reinterpreted** | **PENDING** |
| **G2** | Two dedicated Health edges; `DERIVED_FROM` untouched | Low — strictly stronger than widening | No impact | **PENDING** |
| **G3** | Structured closed grammar; five operators; `instant` + `windowed_count`; **no percentiles in v1** | **Medium** — narrows an exemplar; new ADR | No impact | **PENDING** |
| **G4** | `duration` hysteresis only in v1; required proof fields on CHDEG | **Medium** — narrows "how long or how often" | No impact | **PENDING** |
| **G5** | Explicit invocation + stored historical freshness + recomputation at selection; no daemon | Medium — the stale-label trap | No impact | **PENDING** |
| **G6** | `publication` block on CHENV; **no seventh family**; fallback: ship `withheld` with no producer | **Medium** — mixes publication with limits on one record | No impact | **PENDING** |
| **G7** | `received_at` + required `{epoch, sequence}` + authenticated subject binding + independent-evidence invariant | **Medium-high** — security-load-bearing | No impact | **PENDING** |
| **G8** | `/var/lib/kyri/health`, `cschott:cschott 0700`/`0600`, separate store, read-only adapters | Low — reuses every released pattern | No impact | **PENDING** |
| **G9** | Reuse `collector_id` + `source_fingerprint` + existing registry; contradiction → `unknown` + review | **Medium** — a compromised collector can deny reassurance | No impact | **PENDING** |
| **G10** | `review_required` conditionally required on CHSTATE | Low | No impact | **PENDING** |
| **G11** | **(C)** `degraded` inert in v1; `unavailable` subtracts; (A) as declared future path | **Medium** — narrows a normative sentence whose condition has no referent | **No route change** | **PENDING** |
| **G12** | Three-way mapping; `refused` and `cancelled` count as **neither**; no new dimension | Low-medium | **CRES read-only** | **PENDING** |
| **G13** | Layered binding: schema + ontology + **write-time refusal** | Low — closes a forged-positive path | No impact | **PENDING** |
| **A1** | First CHSTATE is not a transition; no CHDEG | Low — clarification | No impact | **PENDING** |
| **A2** | **Do not rename** CHDEG; clarify in prose | Low | No impact | **PENDING** |
| **B** | Explicit subject/dimension matrix; recommend removing `capability-package` from CHOBS | Medium — narrows a subject enum | No impact | **PENDING** |
| **C** | `health_adapter`: trust-adapter structure, **inverted** failure consequence | **Medium-high** — the misreading risk | No impact | **PENDING** |

**Every normative decision is PENDING. None has been applied.**

---

## 8. Proposed architecture-change set

**NOT APPLIED.** Listed so the reviewer can approve, amend or reject by group.
The only change applied in this increment is the §0 ENG-0006-A count correction.

**ADR-0013 corrections** — line 153 and the state table (C1) · line 244
recommendation vocabulary (C2) · line 162 `withheld` row (C3) · withholding
authority (G6) · evaluation trigger and the two freshness times (G5) · heartbeat
trust model and the independent-evidence invariant (G7) · collector identity and
the contradiction rule (G9) · store root and authority boundary (G8) · the v1
subtraction rule (G11) · the CRES mapping table (G12) · referential integrity
(G13) · first-evaluation clarification and the CHDEG naming note (A1, A2).

**New ADR(s)** — one: the **Health condition and hysteresis grammar** (G3, G4),
carrying operators, numeric representation, the dimension/unit table,
aggregations, window semantics and hysteresis forms. It is a normative policy
language and does not belong in ADR-0013's prose.

**ADR-0012 changes** — one short amendment: the `capability-selection` health
disclosure block and its forward-only boundary (G1), citing ADR-0013 for the
requirement so neither ADR describes a record it does not own.

**Health document corrections** — `selection-visibility.md`: the stale claim that
the released schema carries the block (G1) · `health-states.md`: the "per route
policy" clause (G11), the "six above" residue (C1), what `healthy` requires (G7)
· `operational-envelope.md`: dimension field table (G3), hysteresis row (G4),
`publication` block (G6) · `degradation-semantics.md`: structured conditions (G3),
hysteresis proof (G4), transition-record naming (A2) ·
`unknown-and-freshness.md`: the two freshness times (G5), `review_required` (G10)
· `observation-model.md`: collector identity (G9), CRES as a source (G12),
heartbeat trust model (G7), subject/dimension matrix (B) ·
`governance-boundaries.md`: store boundary (G8), referential integrity (G13).

**Schema changes** — `capability-health-envelope`: structured conditions and
hysteresis (G3, G4), `publication` block (G6) ·
`capability-health-observation`: `collector_id` + `source_fingerprint` (G9),
subject/dimension matrix (B) · `capability-heartbeat`: `received_at`, required
`{epoch, sequence}` (G7) · `capability-health-state`: `review_required` (G10),
subject binding (G13), independent-evidence invariant (G7), freshness comment
(G5) · `capability-degradation-event`: required hysteresis proof (G4), subject
binding (G13) · `capability-health-recommendation`: header comment only (C2),
subject binding (G13) · `capability-selection`: disclosure block (G1).

**Ontology changes** — two new relationship types, `DERIVED_FROM_OBSERVATIONS`
and `FOLLOWS_FROM_STATE`, each with a same-subject requirement (G2, G13).
`DERIVED_FROM` and its four forbidden pairs are **left exactly as released**.

**Future runtime changes** — none in this increment. The twenty-one increments
from ENG-0006-A §L remain **planning input**, and Phase 0 is now populated by
this package rather than by placeholders.

**Future tests** — T1–T14 above, each gated on its decision, plus the
negative-surface and wording assertions which are ungated.

---

## 9. Validation

| Check | Result |
|---|---|
| `tests/test-docs-static.sh` | **passed** |
| `tests/test-capability-health.sh` | **passed** — 461 assertions |
| `tests/test-static.sh` | **passed** |
| ENG-0005 branch untouched | `origin/arch/eng-0005-execution-transition` = `0f36074fa2679cb555cc1d22a7cf14d0475543a3` |
| `v0.11.0` untouched | → `ce0debb8be3c87babf6856fb7f694c590fc667a1` |
| Production Fabric digest | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` — unchanged |
| Production Capability Runtime digest | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` — unchanged |
| Production Trust digest | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` — unchanged |
| Health store | **does not exist** — none created |
| Runtime code changed | **none** |
| Production mutation | **none** |

---

## 10. Result

```
RESULT=REVIEW_REQUIRED
ENG0006_A_CHECKPOINT=719ec60ed9d5f6d7d507c3a9cd0aa2485b269cbb
BRANCH=arch/eng-0006-health-runtime
INCREMENT=ENG-0006-B
CONFLICTS_RESOLVED_IN_PROPOSAL=3
GAPS_RESOLVED_IN_PROPOSAL=13
NORMATIVE_DECISIONS_APPLIED=0
ADR0013_EDITED=NO
ADR0012_EDITED=NO
SCHEMAS_EDITED=NO
ONTOLOGY_EDITED=NO
RUNTIME_CODE_CHANGED=NO
EXISTING_RECORD_REWRITE_REQUIRED=NO
HEALTH_STORE_CREATED=NO
PRODUCTION_FABRIC_MUTATION=NONE
PRODUCTION_CAPABILITY_MUTATION=NONE
PRODUCTION_TRUST_MUTATION=NONE
PRODUCTION_HEALTH_MUTATION=NONE
REPORT=docs/development/reports/eng-0006/2026-10-13-eng-0006-b-architecture-resolution-package.md
NEXT=independent reviewer approves, amends, or rejects each ENG-0006-B architecture decision
STOP
```

**Four decisions deserve the reviewer's attention first**, because they are the
ones where a defensible alternative exists and my recommendation narrows accepted
architecture rather than correcting stale prose:

- **G11** — `degraded` inert in v1. I argue this is the faithful reading of a
  sentence whose stated condition has no referent, but it is a narrowing and the
  reviewer may prefer (A) or (B).
- **G4** — `duration` hysteresis only, dropping "how often" from v1.
- **G3** — no percentile aggregation, which requires correcting a worked example.
- **G6** — `publication` on CHENV rather than a seventh record family, which
  mixes a publication decision into a record whose job is limits. ADR-0013's own
  Accepted Risks already warn that `withheld`'s publication rules may belong
  elsewhere, so option (d) — ship the state with no producer — is a legitimate
  smaller choice.

## Related

- [ENG-0006-A architecture reconciliation](2026-10-12-eng-0006-a-architecture-reconciliation.md)
- [ADR-0013: The Capability Health Plane](../../../decisions/ADR-0013-capability-health-plane.md)
- [ADR-0012: The Distributed Capability Fabric](../../../decisions/ADR-0012-distributed-capability-fabric.md)
- [Capability Health overview](../../../health/capability-health.md)
- [Confidence and Freshness Standard](../../../standards/confidence-freshness-standard.md)
