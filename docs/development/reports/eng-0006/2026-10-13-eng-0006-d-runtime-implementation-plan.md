# ENG-0006-D — Health Runtime implementation plan

**Date:** 2026-10-13 · **Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `80fe105513ed9da668e063f6963c9cb8367191b9` (ENG-0006-C, reviewed and published)

**RESULT: REVIEW_REQUIRED.** Planning only. No runtime code, no Health store, no
ADR, schema or ontology change, no production mutation.

**Throughout this report:** *VERIFIED* marks a fact read from the repository in
this increment; *RECOMMENDATION* marks an engineering judgement for the reviewer
to accept or reject; *UNRESOLVED* marks something no one has decided.

---

## 1. Executive engineering assessment

**The architecture is implementable, and the first four increments need no new
architecture at all.** Three findings shape the plan.

**The storage layer already exists and is a near-exact fit.** *VERIFIED:*
`tools/common/immutable_store.py` provides an `ImmutableStore` base whose
subclasses declare only `record_dirs`, `id_patterns`, `id_prefixes` and
`id_widths`; everything else — flock'd sequence allocation with `fsync` and no
rollover, atomic write with a temporary sibling, `read_record`, `list_records`,
`counts`, and a `request_critical_section` — is inherited. It defaults to
`DIR_MODE = 0o700` / `FILE_MODE = 0o600`, which is exactly what ADR-0013 declares
for the Health store. **A `HealthStore` is a small subclass, not a new
subsystem.**

Two properties of that base class are what make a safe first increment possible.
`ImmutableStore.__init__` **refuses a root inside a git repository** unless
`allow_repository_root=True` is passed explicitly "for a test fixture" — so a
fixture-only increment cannot accidentally write into the repository. And
`open_for_read` exists precisely so that "reading must not change what it
reports": a reader that provisioned the directories it describes would make its
answer partly a description of its own side effects. The read-only Health adapter
must use it.

**The largest single risk is not technical.** It is that the first increment
quietly becomes the whole Health Plane. The architecture's entire purpose is to
keep an observability layer from acquiring authority over the Fabric, and the
mechanism that keeps that true during implementation is the **ordering**: every
component that computes must be built, tested and reviewed before any component
that is *read by* the Fabric. This plan therefore puts four pure, fixture-only
increments first, and places the two increments that change Fabric behaviour
behind their own named gates: **H15**, the first Fabric **write** crossing, which
introduces mandatory CSEL Health disclosure, and **H16**, the first Fabric
**decision** crossing, which enables governed Health subtraction. **H13 is not a
selection crossing** — it is read-only execution-outcome collection, gated because
it is the first component to read another plane's records.

**The baseline validation debt is worse than ENG-0006-C reported, and the
diagnosis it offered is wrong.** ENG-0006-C said three pre-existing failures; the
complete inventory is **28 of 153**. My published follow-up split those into "18
environment-specific, 10 reproducible" using isolated worktrees. *VERIFIED in this
increment:* **26 of those 28 suites exercise a provisioning ceremony that
hard-codes `REPOSITORY="/opt/schott-platform"`** while the suite computes its own
root from `SCRIPT_DIR/..`. In a worktree those two diverge, so the suite checks
one tree while the ceremony operates on another — **the worktree runs are not a
valid baseline for 26 of the 28, and the 18/10 split cannot be relied on.** I also
tested the `__pycache__` hypothesis directly and **refuted it** (§10). What
survives is the conclusion that matters most: ENG-0006-C introduced none of them,
proven two independent ways.

---

## 2. Verified starting repository state

*All VERIFIED in this increment.*

| Check | Result |
|---|---|
| Branch | `arch/eng-0006-health-runtime` |
| Local HEAD | `80fe105513ed9da668e063f6963c9cb8367191b9` — matches required |
| Remote HEAD | `80fe105513ed9da668e063f6963c9cb8367191b9` — published, in sync |
| Worktree | clean: 0 modified, 0 staged, 0 untracked |
| Registered git worktrees | 1 (the main tree only; temporary baseline worktrees removed) |
| `/var/lib/kyri/health` | **does not exist** (`statx` → No such file or directory, through a traversable parent) |
| `/data/kyri/capability-health` | does not exist |
| `CH*` records anywhere under `/var/lib/kyri` or `/data/kyri` | **0** |
| `tools/health` | does not exist |
| Any Health module under `tools/` | **0 files** matching `*health*` |
| Production Fabric | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| Production Capability Runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| Production Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |

**A provisioning constraint found while verifying the above.** *VERIFIED:*
`/var/lib/kyri` is `root:root 0711` — traversable but **not listable** by
`cschott`. Its existing children `fabric` and `trust` are `cschott:cschott 0700`.
**The Health Runtime therefore cannot create its own store root**: a root-owned
directory must be created and chowned by an operator ceremony before any Health
component can initialise. That is increment **H18**, the operator store-provisioning
ceremony, and it is the reason the first increment is fixture-only rather than
"create the store and start small".

**Verified implementation surfaces that the plan depends on:**

| Surface | Verified fact |
|---|---|
| `tools/common/immutable_store.py` | 305 lines. `ImmutableStore` with `record_dirs`/`id_patterns`/`id_prefixes`/`id_widths`, `extra_dirs = ("sequences",)`, `DIR_MODE 0o700`, `FILE_MODE 0o600`, `MAX_SEQUENCE 999_999` |
| Git-root refusal | `__init__` raises `StoreError` when the root is inside a git repository unless `allow_repository_root=True` |
| Read without provisioning | `open_for_read(root, ...)` constructs with `initialize=False` |
| Identifier allocation | `allocate_id` — `flock(LOCK_EX)`, read-modify-write, `fsync`, refuses rollover: widening is "a deliberate decision, not an automatic rollover" |
| Base `validate()` | reads `record.get("id")` — **Fabric records do not use an `id` key** (they use `selection_id`, `route_id`, …) and `FabricStore` **overrides `validate()`** at `tools/fabric/store.py:480`. A `HealthStore` must override it too |
| Adapter precedent | `tools/fabric/trust_adapter.py` — reports an answer, owns no verdict, fails closed to one value, remembers nothing, instant from the caller, refusals from a controlled vocabulary (`REASON_NO_STANDING`, `REASON_EXPIRED`, `REASON_REVOKED`, `REASON_NOT_USABLE`, `REASON_UNREADABLE`, `REASON_UNAVAILABLE`, `REASON_SUBJECT_TYPE_MISMATCH`) |
| Fabric health hook | `tools/fabric/selection.py` — `REASON_HEALTH_REMOVED = "candidate-removed-by-health-input"`, `health_removals` parameter folded into the request digest, applied **after** `evaluate_eligibility`; **not reachable from the CLI** |
| Eligibility | `tools/fabric/eligibility.py` — twelve conditions `ELIG-1`…`ELIG-12`; quarantine is `ELIG-10`; `availability_intent` must equal `in-service` (line 624). **Health is not an eligibility condition** |
| Capability/Health barrier | `tests/test-capability-runtime.sh:143-145` forbids `tools.health`, `..health`, `liveness`, `readiness`, `heartbeat` **by module name** |
| Collector registry | `tools/collectors/registry.py` — `CollectorRegistry.get()` raises `CollectorRegistrationError` for an unregistered id; `ids()`, `list_manifests()` |
| Released outcome vocabulary | `tools/capability/records.py:101` — eight classes: `completed`, `refused`, `adapter-error`, `provider-error`, `timeout`, `cancelled`, `interrupted`, `serialisation-failure` |
| Global Fabric schema version | `tools/fabric/models.py:36` — one value `"schott-platform/v1"` for all eight families, enforced by equality at line 296 |
| Unknown-key handling | `models.py:303-307` refuses unknown keys and **never checks for missing ones** |
| Agreement suite | 88/88 passing, exit 0 |
| Health suite | 464/464 passing, exit 0 |

---

## 3. Component inventory

**Twenty-one components** — the twenty the brief lists to evaluate, with
persistence split into the store boundary (B1) and sequence allocation (B2)
because they have different failure modes and different tests. *All specification
references VERIFIED against the repository.* "Production-safe" means implementable
without modifying any production runtime, store or configuration.

**Note on identifiers.** The derivation components are `D1c`–`D3c`, suffixed so
they cannot be confused with the deferred decisions **D1**–**D7** in §7. They are
unrelated numbering schemes.

### Layer A — pure computation (no I/O, no store)

**A1. Health record models and serialisation**
- **Purpose:** typed, frozen, schema-conformant representations of the six Health families.
- **In/out:** mappings in, frozen record objects out; `to_dict()` back.
- **Spec:** the six schemas; the `FabricRecord` pattern (`kind`, `_TIMESTAMPS`, `_SEQUENCES`, `_freeze`, `_seal`, `deep_freeze`).
- **Upstream:** none.
- **Permissions:** none. **Trust boundary:** none — pure data.
- **Failure:** refuse on malformed input; never echo a rejected value; controlled refusal vocabulary.
- **Tests:** every required field refused when absent; every forbidden field refused when present; frozen-ness; round-trip; unknown keys refused.
- **Deferred:** none. **Production-safe:** yes.

**A2. Subject identity and reference validation**
- **Purpose:** enforce the G13 binding — a record's subject must equal the subject of every record it cites.
- **In/out:** a record plus its cited records; a verdict with a mismatch class.
- **Spec:** `subject_binding: must-match-every-cited-record`, `identifier_format_sufficient: false`, `cross_subject_citation: refuse`, `nonexistent_reference: refuse` on CHSTATE/CHDEG/CHREC; the two ontology edges with `same_subject_required: true`.
- **Upstream:** A1.
- **Permissions:** none. **Trust boundary:** this is the forged-positive-claim defence; a cross-subject citation is well-formed and false.
- **Failure:** refuse; name the mismatch class; echo no value.
- **Tests:** cross-subject citation refused for all three families; absent reference refused rather than skipped; envelope-subject mismatch refused; identifier-format-only validation proven insufficient.
- **Deferred:** none. **Production-safe:** yes.

**A3. Condition grammar evaluator**
- **Purpose:** deterministic evaluation of a structured condition against observations.
- **In/out:** `{operator, value}` + `unit` + `aggregation` + observations → satisfied / not / `unknown`.
- **Spec:** ADR-0019; CHENV `condition_operators`, `condition_value_representation: decimal-string`, `aggregations`, `dimension_units`, `unit_mismatch: refuse`, `percentile_aggregation: forbidden`.
- **Upstream:** A1.
- **Permissions:** none. **Trust boundary:** the threshold-manipulation surface. No parser; no expression strings.
- **Failure:** a unit mismatch refuses; a `windowed_count` without `min_samples` refuses; too few usable samples → `unknown`, never `healthy` or `degraded`.
- **Tests:** each of the five operators; exact-decimal comparison (binary-float equivalence must fail); unit mismatch refused; percentile rejected; no-usable-observation → `unknown`; windowed count under `min_samples` → `unknown`.
- **Deferred:** **D6** (percentile must stay rejected). **Production-safe:** yes.

**A4. Freshness evaluator**
- **Purpose:** per-dimension freshness, and the two-freshness separation.
- **In/out:** observations + per-dimension policy + evaluation instant → `current`/`aging`/`stale`/`unknown` per dimension, plus `review_required`.
- **Spec:** Confidence and Freshness Standard; CHSTATE `stored_freshness: freshness-at-evaluated-at`, `stored_freshness_authoritative_for_eligibility: false`, `freshness_recomputed_at_use: true`; CHOBS freshness enum.
- **Upstream:** A1.
- **Permissions:** none. **Trust boundary:** a stored `current` must never be usable as proof of present freshness.
- **Failure:** a null policy → `unknown` **with** `review_required: true`; no evidence → `unknown`, never `stale`.
- **Tests:** null policy yields `unknown` + flag; absent evidence yields `unknown` not `stale`; per-dimension independence (current latency alongside stale availability); a stored label is never read for an eligibility decision.
- **Deferred:** none. **Production-safe:** yes.

**A5. Hysteresis and continuity evaluator**
- **Purpose:** decide whether a transition is recordable, and produce its proof.
- **In/out:** envelope hysteresis + ordered observations → satisfied/not + interval bounds, sample count, observed max gap.
- **Spec:** ADR-0019 continuity rules; CHENV `hysteresis_kinds: [duration]`, `hysteresis_fields.required`, `hysteresis_continuity` incl. `gap_cause_affects_reset: false`; CHDEG six required proof fields, `unprovable_transition: refuse`.
- **Upstream:** A1, A3, A4.
- **Permissions:** none. **Trust boundary:** a gap must not become a violation; a monitoring outage must not manufacture a transition.
- **Failure:** unsatisfied → no transition; unprovable → refuse.
- **Tests:** duration met/unmet; coverage below `min_samples` → no transition; gap over `max_gap_seconds` resets; **boundary** gaps reset; a non-violating usable observation resets; a collection-failure gap resets (the security case); `occurrences` rejected; every proof field present or refuse.
- **Deferred:** none. **Production-safe:** yes.

### Layer B — persistence

**B1. Health store and filesystem boundary**
- **Purpose:** the append-only Health store.
- **In/out:** a root path; record read/write/list/count/validate.
- **Spec:** ADR-0013 store section (`/var/lib/kyri/health`); `governance-boundaries.md` direction matrix; `ImmutableStore`.
- **Upstream:** A1.
- **Permissions:** write only within its own root. **Never** a write path to the Fabric or Trust roots.
- **Trust boundary:** separation is the mechanism — filesystem authority rather than application discipline.
- **Failure:** refuse a root inside a git repository unless an explicit fixture opt-in; a partial write leaves a `.tmp` that `validate()` reports.
- **Tests:** six record dirs and six sequences created; modes `0700`/`0600`; **`validate()` overridden** for Health identifier keys; no write path to Fabric or Trust by module and by path; rollover refused at width.
- **Deferred:** none. **Production-safe:** yes **with fixture roots only**; the production root is created by H18.

**B2. Sequence allocation and identifier widths**
- **Purpose:** `CHENV-0000` (4 digits) and the five six-digit families.
- **Spec:** the six `id_pattern`s; `allocate_id`; `id_widths`.
- **Upstream:** B1. **Failure:** exhaustion refuses rather than rolling over.
- **Tests:** width per family; monotonic under concurrency; exhaustion refused; no reuse after a refused write.
- **Deferred:** none. **Production-safe:** yes (fixtures).

### Layer C — evidence ingestion

**C1. Envelope ingestion (human-authored)**
- **Purpose:** accept an operator-authored envelope.
- **Spec:** CHENV `authored_by: human`, `threshold_source: declared-only`, `change_requires: immutable-approval`, `baseline_promotion: forbidden`, `violation_widens_threshold: false`; ADR-0019 required members.
- **Upstream:** A1, A3, A5, B1.
- **Permissions:** reads an operator-reviewed input location; writes the Health store. **Authoring a threshold and running the evaluator must not be the same authority.**
- **Failure:** refuse a learned/derived/auto threshold field; refuse missing continuity members; refuse a unit mismatch.
- **Tests:** every forbidden envelope field refused; missing `max_gap_seconds` or `min_samples` refused; no-envelope → `unmonitored`; partial envelope → `insufficient-policy` per metric.
- **Deferred:** **D1** (no `publication` block may be added). **Production-safe:** yes (fixtures).

**C2. Envelope versioning and supersession**
- **Spec:** `supersession: new-record-only`, `supersession_rewrites_prior_evaluations: false`.
- **Upstream:** C1. **Failure:** an edit attempt refuses.
- **Tests:** the `worked-examples.md` example 7 case as an executable test — one observation, two envelope versions, two results, neither rewritten; a later version does not clear a prior `review_required`.
- **Deferred:** none. **Production-safe:** yes.

**C3. Collector identity and provenance verification**
- **Purpose:** bind an observation to a governed collector.
- **Spec:** CHOBS `collector_id` + `source_fingerprint` required, `collector_identity: closed-registry`, `free_text_source: forbidden`, `source` in `forbidden_fields`; `tools/collectors/registry.py`.
- **Upstream:** A1, B1.
- **Trust boundary:** a forged observation naming an arbitrary origin must be refused. A forged **good**-health observation is the more valuable attack.
- **Failure:** unregistered `collector_id` refuses; a free-text `source` field refuses.
- **Tests:** unregistered id refused; registry `ids()` agrees with the schema constraint; `source` refused; fingerprint required.
- **Deferred:** none. **Production-safe:** yes — reads the registry, writes nothing of the Capability Runtime's.

**C4. Observation ingestion**
- **Spec:** CHOBS required fields; `collection_failure_implies_subject_failure: false`; `dimension_subjects` matrix.
- **Upstream:** A1, A2, C3, B1.
- **Failure:** `failed`/`unavailable` status carries **no** `measured_value`; a zero is never substituted; a package subject refuses.
- **Tests:** failed collection has null value and concludes nothing; package subject refused for every runtime dimension; dimension/unit mismatch refused; contradicting fresh sources → `unknown` with all cited and `review_required`.
- **Deferred:** **D3** (no platform-side dimension), **D4** (package stays out). **Production-safe:** yes.

### Layer D — derivation

**D1c. Health state derivation**
- **Spec:** CHSTATE `evaluation: deterministic`, `worst-dimension-wins`, `default_state: unknown`, `healthy_requires_independent_evidence: true`, `envelope_of_only_subject_reported_dimensions: insufficient-policy`, `evaluation_trigger: explicitly-invoked`, `background_writer: none`, `first_evaluation_is_transition: false`.
- **Upstream:** A1–A5, B1, C1–C4.
- **Trust boundary:** the only stage permitted to conclude. A collector must never write a state; a subject must never establish its own health.
- **Failure:** any `unknown` dimension prevents `healthy`; a malformed citation refuses the whole record, never a partial one.
- **Tests:** identical inputs → identical state, asserted by repeated derivation; heartbeat-only envelope → `insufficient-policy`; subject-reported dimensions alone never `healthy`; stale `degraded` stays `degraded` and never becomes `healthy`; `unknown` never clears a prior finding; no daemon exists.
- **Deferred:** **D1** (never emit `withheld`). **Production-safe:** yes.

**D2c. Degradation-event derivation**
- **Spec:** CHDEG required proof fields; `first_evaluation_is_transition: false`; `unchanged_state_produces_event: false`; `records: all-health-state-transitions`.
- **Upstream:** D1c, A5.
- **Tests:** first evaluation emits none; unchanged re-derivation emits none; every transition including recovery emits exactly one; a missing proof field refuses.
- **Deferred:** none. **Production-safe:** yes.

**D3c. Recommendation derivation**
- **Spec:** CHREC closed four-value enum; `is_action: false`, `advisory_only: true`, `requires_human_action: true`, `auto_execution: forbidden`; the forbidden-field list.
- **Upstream:** D1c, D2c, A2.
- **Trust boundary:** the layer's authority ends here. No execution surface may exist, even unused.
- **Tests:** only the four values accepted; every forbidden field refused by name; `review_required` and `advisory_only` carried on the record; no execution field can be added and still pass.
- **Deferred:** none. **Production-safe:** yes.

### Layer E — external evidence

**E1. Execution-outcome collector (CRES → CHOBS)**
- **Spec:** ADR-0013 attribution table; CHOBS `failure_count_counts: subject-attributable-only`, `platform_side_failures_count: never`, `ambiguous_failures_count: never`; `tools/capability/records.py` `OUTCOME_CLASSES`.
- **Upstream:** C3, C4.
- **Permissions:** **read-only** over the Capability Runtime store. No write, ever.
- **Trust boundary:** the direction is one-way. The Capability Runtime pushes nothing; the barrier test must keep passing unaltered.
- **Failure:** an unmapped outcome class refuses rather than defaulting.
- **Tests:** all eight classes mapped, none unmapped; `refused` and `cancelled` increment neither counter; `adapter-error`, `serialisation-failure`, `timeout`, `interrupted` never reach `failure-count`; the Capability Runtime still imports nothing from Health.
- **Deferred:** **D2** (ambiguous outcomes stay unattributed), **D3**. **Production-safe:** yes — read-only.

**E2. Heartbeat receiving and replay protection**
- **Spec:** CHBEAT `freshness_input: received_at`, `epoch_authored_by: health`, `epoch_bound_to: authenticated-session`, `epoch_self_advancement: forbidden`, `subject_identity_binding: authenticated-channel-identity`, replay/duplicate/out-of-order/missing-sequence all `refuse`.
- **Upstream:** A1, B1, C3 — **and an authenticated transport that does not exist.**
- **Trust boundary:** a subject must not refresh its own apparent liveness.
- **Status:** **BLOCKED BY D5.** See §7. Not scheduled.
- **Production-safe:** n/a — not authorised.

### Layer F — integration

**F1. Read-only Health adapter**
- **Purpose:** the Fabric's only route to Health standing.
- **Spec:** ADR-0013; `trust_adapter.py` as the structural precedent with **inverted** failure consequence; the §9 outcome table.
- **Upstream:** A4, D1c, B1 (`open_for_read`).
- **Permissions:** read-only over the Health store. The Fabric holds **no** write path to it.
- **Trust boundary:** recomputes freshness; never reads a stored label for a decision; **every failure mode yields no subtraction.**
- **Failure:** absent, unreadable, unavailable, malformed, unverifiable, stale, `unknown`, `unmonitored`, `insufficient-policy`, `withheld` → **no Health subtraction**, which is *not* a statement that the candidate is eligible.
- **Tests:** each of the ten inputs produces no subtraction; fresh `unavailable` produces one; `healthy` adds nothing; the adapter provisions nothing (`open_for_read`); no clock of its own; refusal vocabulary leaks no path or value.
- **Deferred:** **D7** (`degraded` stays inert). **Production-safe:** yes — reads Health, touches no Fabric file.

**F2. Fabric selection Health disclosure**
- **Spec:** CSEL `health_disclosure` / `candidate_health` conditionally required; `health_disclosure_boundary` (closed set, `disclosure_required_from: CSEL-000006`); ADR-0012 amendment.
- **Upstream:** F1.
- **Trust boundary:** **FIRST CROSSING INTO FABRIC BEHAVIOUR.** Changes what the Fabric writes.
- **Failure:** a new selection without disclosure is **invalid**, not legacy.
- **Tests:** all nine input cases distinguishable in a written record; the five legacy identities still load and report as pre-disclosure; a new write cannot omit disclosure; disclosure is never caller-supplied.
- **Deferred:** none. **Production-safe:** **NO** — modifies a production record family's writer.

**F3. Eligibility subtraction integration**
- **Spec:** `selection.py` `health_removals` + `REASON_HEALTH_REMOVED`; ADR-0013 subtraction rule.
- **Upstream:** F1, F2.
- **Trust boundary:** changes what the Fabric **decides**.
- **Tests:** only fresh `unavailable` subtracts; quarantine still wins; `availability_intent` still wins; candidate order never reordered; a malformed Health store empties no route.
- **Deferred:** **D7**. **Production-safe:** **NO.**

### Layer G — operations

**G1. Operator inspection and audit tooling**
- **Purpose:** answer the three audit questions from records alone.
- **Spec:** ADR-0013 audit requirements; `governance-boundaries.md`.
- **Upstream:** B1, D1c–D3c. **Permissions:** read-only.
- **Tests:** "was this capability healthy when that request was routed to it" answerable from records; evidence chain reachable; no mutation path in the CLI.
- **Deferred:** none. **Production-safe:** yes.

**G2. Production store provisioning**
- **Purpose:** create `/var/lib/kyri/health` with correct ownership.
- **Spec:** ADR-0013; the verified `/var/lib/kyri` = `root:root 0711` constraint.
- **Permissions:** **root**, via an operator ceremony. The runtime cannot create its own root.
- **Tests:** ceremony is idempotent; modes and ownership asserted; refuses if the root exists with wrong ownership; creates no records.
- **Deferred:** none. **Production-safe:** **NO** — touches the host.

---
## 4. Dependency graph

Edges are "must exist first". The double line is the authority boundary: nothing
below it may be built until everything above it is implemented, tested and
independently reviewed.

```
LAYER A — pure, fixture-only, no store
  A1 record models ──┬──> A2 subject binding
                     ├──> A3 condition grammar ──┐
                     └──> A4 freshness ──────────┼──> A5 hysteresis / continuity
                                                 │
LAYER B — persistence (fixture roots)            │
  A1 ──> B1 health store ──> B2 sequences        │
                                                 │
LAYER C — evidence ingestion                     │
  A1,A3,A5,B1 ──> C1 envelope ──> C2 versioning  │
  A1,B1 ───────> C3 collector identity ──┐       │
  A1,A2,C3,B1 ─> C4 observation ingestion┘       │
                                                 │
LAYER D — derivation (the only stage that concludes)
  A1..A5 + B1 + C1..C4 ──> D1c health state
                              ├──> D2c degradation event   (needs A5)
                              └──> D3c recommendation      (needs A2)
LAYER E — external evidence
  C3,C4 ──> E1 CRES collector  (read-only over Capability Runtime)
  E2 heartbeat receiver ....... BLOCKED BY D5, not scheduled
LAYER F — integration
  A4,D1c,B1 ──> F1 read-only health adapter     (reads Health; touches no Fabric file)
════════════════════════ AUTHORITY BOUNDARY ════════════════════════
  F1 ──> F2 CSEL disclosure        <-- FIRST CROSSING: changes what the Fabric WRITES
  F2 ──> F3 eligibility subtraction      changes what the Fabric DECIDES
LAYER G — operations
  B1,D1c..D3c ──> G1 inspection tooling (read-only, any time after D3c)
  G2 production store provisioning (root ceremony; required before any production use)
```

**Three orderings are load-bearing rather than convenient.**

**A5 after A3 and A4.** Continuity is defined over *usable* observations, and
"usable" means collected, valued **and within the freshness policy** — so
hysteresis cannot be evaluated before freshness exists. Building A5 first would
force an implementer to invent a definition of usable.

**F1 before F2.** The adapter is the only thing that can answer "what does Health
say about this candidate". Building the disclosure first would mean writing the
answer's shape before its source exists, which is how a record ends up carrying a
field no adapter can populate honestly.

**G1 may precede F1.** Operator inspection reads Health records and touches no
Fabric surface, so audit tooling can land before anything crosses the boundary —
which is the right order: the ability to *review* Health should exist before
Health influences anything.

---

## 5. Proposed increment sequence

**Eighteen increments.** *RECOMMENDATION.* Optimised for reviewability and for
keeping the authority boundary visible, not for increment count.

| # | Increment | Components | Crosses into Fabric? | Gate |
|---|---|---|---|---|
| **H1** | Health record models and schema conformance | A1 | no | standard |
| **H2** | Subject binding and reference validation | A2 | no | standard |
| **H3** | Condition grammar evaluator | A3 | no | standard |
| **H4** | Freshness evaluator | A4 | no | standard |
| **H5** | Hysteresis and continuity evaluator | A5 | no | standard |
| **H6** | Health store subclass (fixture roots only) | B1, B2 | no | standard |
| **H7** | Envelope ingestion, versioning, supersession | C1, C2 | no | standard |
| **H8** | Collector identity verification | C3 | no | standard |
| **H9** | Observation ingestion | C4 | no | standard |
| **H10** | Health state derivation | D1c | no | **architecture gate** — first component permitted to conclude |
| **H11** | Degradation-event derivation | D2c | no | standard |
| **H12** | Recommendation derivation | D3c | no | standard |
| **H13** | Execution-outcome collector | E1 | no — read-only | **boundary gate** — first component reading another plane |
| **H14** | Read-only Health adapter | F1 | no | standard |
| **H15** | **CSEL Health disclosure** | F2 | **YES — FIRST CROSSING** | **INDEPENDENT APPROVAL GATE** |
| **H16** | Eligibility subtraction | F3 | **YES — changes decisions** | **INDEPENDENT APPROVAL GATE** |
| **H17** | Operator inspection tooling | G1 | no | standard; may land any time after H12 |
| **H18** | Production store provisioning ceremony | G2 | no — host only | **operator gate** |

**Fifteen of the eighteen cross nothing**: H1–H14 and H17. **Two cross into Fabric
behaviour**: H15 and H16, each behind its own independent approval gate. **One is
an operator host ceremony**: H18. The heartbeat receiver is a nineteenth component
that is **not scheduled at all**, because D5 is unresolved.

**Not scheduled:** the heartbeat receiving surface (E2). **Blocked by D5.**

**Why H1–H9 before H10.** H10 is the first component permitted to *conclude*
anything. Everything before it either represents data or computes a pure
function, and each can be proven against fixtures with no store and no
production surface in reach. If H10 is reached with H1–H9 reviewed, the
derivation increment is a composition of proven parts rather than a new subsystem.

**Why H13 (the CRES collector) has its own gate** even though it is read-only: it
is the first component that reads a *different plane's* records, and the
Capability/Health barrier is enforced by module name in an existing suite. A
reviewer should confirm the direction stayed one-way before anything else depends
on it.

---

## 6. Detailed first-increment contract — H1

**RECOMMENDATION: H1 is Health record models and schema conformance, and nothing
else.** The brief asks whether the first increment should contain the pure models
*plus* condition, freshness and hysteresis evaluation. **I recommend splitting
those into H2–H5 rather than bundling them.** Bundling would put four independent
specifications — the six schemas, ADR-0019's grammar, the Confidence and
Freshness Standard, and ADR-0019's continuity rules — into one review, and the
continuity rules in particular are the subtlest thing in the architecture. They
deserve a review of their own.

| | |
|---|---|
| **Identifier** | ENG-0006-H1 |
| **Scope** | Frozen, typed record models for the six Health families, with schema-conformant serialisation and refusal. Representation only: **no evaluation, no derivation, no store, no I/O beyond reading fixtures.** |
| **Allowed files** | `tools/health/__init__.py`, `tools/health/records.py`, `tools/health/errors.py`; `tests/test-health-records.sh`; registration lines in `tools/dev/run-validation.sh` and `.github/workflows/ci.yml`; an ENG-0006-H1 report. |
| **Forbidden changes** | Any ADR. Any schema. The ontology. Any file under `tools/fabric/`, `tools/capability/`, `tools/trust/`, `tools/collectors/`, `provisioning/`, `scripts/`. Any existing test except the two registration lines. Creating `/var/lib/kyri/health`. Any store class. Any network or subprocess call. Any `CH*` record outside a fixture directory. |
| **Entry prerequisites** | HEAD is the reviewed ENG-0006-D commit; worktree clean; agreement suite 88/88 exit 0; Health suite 464/464 exit 0; no Health store exists; D1–D7 still unresolved and respected. |
| **Required tests** | A new suite that **fails against an incorrect implementation**: every required field refused when absent (6 families); every forbidden field refused when present, by name; frozen records reject mutation; `to_dict()` round-trips; unknown keys refused; a refusal message contains no rejected value; `capability-package` refused as a subject for all six families; the seven-state and four-kind vocabularies accepted and nothing else. **RED-before-GREEN required**: the suite must be written first and shown failing against an empty `tools/health/records.py`. |
| **Acceptance criteria** | New suite exit 0. Agreement suite still 88/88 exit 0. Health suite still 464/464 exit 0. `test-docs-static.sh`, `test-static.sh`, `test-platform-model.sh`, `test-developer-experience.sh` all exit 0. ShellCheck clean on new and modified shell files. The 28 baseline failures unchanged in membership — **neither repaired nor added to**. No new file outside the allowed list. `/var/lib/kyri/health` still absent. Production digests unchanged. |
| **Failure / rollback** | Pure additive new module. Rollback is `git revert` of a single commit; nothing to un-deploy, no store to clean, no record to remove. If the suite cannot be made to fail against an empty implementation, **stop** — the test is measuring the implementation rather than the specification. |
| **Review evidence** | RED output with assertion counts; GREEN output; the four unchanged suite results with exit codes; a diff file list; a statement that the 28 baseline failures are unchanged; production digests before and after. |
| **Explicit stop condition** | Stop after the report is committed. Do not begin H2. Do not create a store. Do not import anything from `tools/fabric` or `tools/capability`. |

---

## 7. Deferred-decision dependency matrix

*All seven preserved from ENG-0006-C. None resolved here.*

| ID | Unresolved question | Earliest increment affected | Effect if left unresolved | Blocks |
|---|---|---|---|---|
| **D1** | Who may cause Health to publish `withheld`? | **H7** (envelope ingestion must refuse a `publication` block) and **H10** (derivation must never emit `withheld`) | `withheld` stays in the vocabulary with no producer. Everything else derives normally. | one component |
| **D2** | Are `timeout`/`interrupted` attributable to the instance? | **H13** (CRES collector) | Both excluded from `failure-count`. Conservative and safe; some signal unused. | one component |
| **D3** | A platform-side failure dimension? | **H9** (observation ingestion must not accept one) | No such dimension exists. Purely additive if later approved. | nothing |
| **D4** | Package integrity evidence | **H1** (package refused as a subject) and **H9** | Package has a declared owner (Integrity plane) and no record. | nothing in Health |
| **D5** | **How is the heartbeat transport authenticated?** | **E2 — not scheduled** | No heartbeat receiver, no network listener, no heartbeat-driven subtraction. `heartbeat-freshness` can only be populated by an independent collector, if at all. | **a hard boundary** |
| **D6** | Percentile aggregation | **H3** (grammar must reject it) | Instant + `windowed_count` only. Additive later; invalidates no envelope. | nothing |
| **D7** | Route-level `degraded` policy | **H14** (adapter) and **H16** (subtraction) | `degraded` inert, `unavailable` subtracts. | nothing |

### D5 is a hard implementation boundary

**VERIFIED:** the schemas declare `epoch_authored_by: health`,
`epoch_bound_to: authenticated-session`, `epoch_self_advancement: forbidden`,
`subject_identity_binding: authenticated-channel-identity`, `freshness_input:
received_at`, and `refuse` for replay, duplicate, out-of-order and missing
sequence. All fourteen declared controls are present and internally consistent.

**They are declarations in YAML with no runtime and no transport.** "Bound to the
authenticated session" binds to nothing until something authenticates a session.
A heartbeat receiver built on these declarations alone would accept whatever
reached it and stamp a Health-authored `received_at` on it, which is strictly
worse than no receiver: it would manufacture liveness evidence with the
appearance of governance.

**Therefore, and explicitly: no heartbeat receiver, no network listener, and no
heartbeat-driven Health subtraction may be authorised before D5 is independently
resolved.** E2 is absent from the increment sequence rather than placed late in
it, so that no ordering decision can quietly admit it.

One consequence worth stating: with E2 unbuilt, the `heartbeat-freshness`
dimension has no producer. A subject's liveness can only be observed by an
independent collector — which is the architecture's preference anyway, since
`healthy` already requires independent evidence.

---

## 8. Security and privilege boundaries

| Boundary | Rule | Enforcement |
|---|---|---|
| Health → Fabric store | **no write path, ever** | separate store roots; filesystem ownership; a by-module and by-path test |
| Health → Trust store | **no read as evidence, no write** | ADR-0011 directionality; the four `DERIVED_FROM` forbidden pairs; no Health relationship edge names a trust type |
| Fabric → Health store | **read-only, through the adapter only** | `open_for_read`; no Fabric write path |
| Capability Runtime → Health | **none, in either direction from the Capability side** | `tests/test-capability-runtime.sh:143-145` forbids `tools.health`, `..health`, `liveness`, `readiness`, `heartbeat` by name — **this test must keep passing unaltered through every increment** |
| Health → Capability store | **read-only** (H13 only) | collector reads `capability-result`; no write |
| Store root creation | **root ceremony only** | `/var/lib/kyri` is `root:root 0711`; the runtime cannot create its own root |
| Envelope authoring | **human, with approval** | operator-reviewed input location, separate from the evaluator's authority |
| Collector identity | **closed registry** | `CollectorRegistry.get()` refuses unregistered ids |
| Subject self-report | **never independent evidence** | `healthy_requires_independent_evidence: true` |
| Recommendation | **no execution surface, even unused** | CHREC forbidden-field list asserted by name |
| Repository safety | **no store inside the repo** | `ImmutableStore` refuses a git-internal root unless a fixture opts in |

**Privilege summary.** H1–H14 and H17 need **no privilege beyond the `cschott`
user and no write access outside fixture directories**. H15 and H16 write
`capability-selection` records as the Fabric already does. H18 needs **root**, once,
through an operator ceremony.

**The inverted failure semantics, restated because it is the thing most likely to
be implemented backwards.** `trust_adapter` resolves absent, expired, revoked,
malformed, unreadable and unavailable to one value, `unverified`, and that value
**removes** eligibility. The Health adapter resolves the same six conditions to
one outcome too — **no subtraction** — the opposite effect. Same structure,
inverted consequence. "No Health subtraction" means only that Health did not
remove the candidate; eligibility remains decided by the twelve `ELIG`
conditions, quarantine, `availability_intent`, scope and revocation, all of which
run before Health is consulted.

---

## 9. Test-first validation matrix

**The two existing results establish architecture consistency, not runtime
correctness.** *VERIFIED:* agreement suite 88/88 exit 0; Health suite 464/464
exit 0. Both read declarations. **Neither can fail against a wrong
implementation, because there is no implementation.** Every runtime increment must
add behavioural tests that can.

| Test class | What it proves | Where it lives | Can fail against a wrong implementation? |
|---|---|---|---|
| Single-artefact schema validation | a declaration says what it should | `test-capability-health.sh` | no |
| Cross-artefact agreement | independent sources agree | `test-capability-health-agreement.sh` | no |
| **Runtime contract** | a function computes the specified result | new per-increment suites | **yes** |
| **Security / adversarial** | a forged, replayed or substituted input is refused | new per-increment suites | **yes** |
| **Filesystem / permission** | modes, ownership, no cross-plane write path | H6, H18 | **yes** |
| **Integration** | the adapter and Fabric behave as specified | H14–H16 | **yes** |
| **Production readiness** | full-platform validation, store provisioning | H18 + release gate | **yes** |

**The anti-tautology rule.** *RECOMMENDATION:* no test may import a constant from
the module under test and assert the module equals it. Expected values come from
the schema, the ADR, or a literal written in the test. A test that reads
`records.REQUIRED_FIELDS` and checks the record requires exactly those fields
proves only that a tuple is self-consistent — the ENG-0005 F4 class, which this
arc has already produced once.

**RED-before-GREEN is required where the increment closes a specification gap or
adds a refusal**, which is H1–H14. For a purely additive module the RED state is
the suite running against an empty implementation; that is a real signal and it
is cheap.

**Negative tests, by increment:**

| Increment | Required negative tests |
|---|---|
| H1 | malformed record; missing required field; forbidden field present; unknown key; package subject; mutation of a frozen record |
| H2 | cross-subject citation; nonexistent reference; envelope-subject mismatch; identifier-format-only validation insufficient |
| H3 | unit mismatch; percentile; `windowed_count` without `min_samples`; no usable observation; binary-float equivalence |
| H4 | null policy without `review_required`; absent evidence reported as `stale`; collapsed subject-level age |
| H5 | gap over maximum; boundary gap; coverage under `min_samples`; non-violating observation mid-interval; collection-failure gap; `occurrences`; missing proof field |
| H6 | store root inside the repository; wrong modes; `.tmp` residue; width exhaustion; a write path to Fabric or Trust |
| H7 | learned/derived/auto threshold; missing continuity member; a `publication` block (D1) |
| H8 | unregistered `collector_id`; free-text `source`; missing fingerprint |
| H9 | failed collection carrying a value; zero substituted for a failure; contradicting sources resolved to a winner; package subject |
| H10 | `withheld` emitted; `healthy` from subject-reported dimensions only; stale `degraded` becoming `healthy`; `unknown` clearing a finding; non-deterministic repeat |
| H11 | event on first evaluation; event on unchanged state; unprovable transition |
| H12 | a fifth recommendation kind; any forbidden field; an execution surface |
| H13 | an unmapped outcome class; `refused` or `cancelled` counted; an ambiguous class attributed; a write to the Capability store |
| H14 | every one of the ten adapter inputs producing a subtraction it should not; the adapter provisioning a store; the adapter reading a clock |
| H15 | a new selection without disclosure; a legacy record reinterpreted; caller-supplied disclosure; the five legacy identities failing to load |
| H16 | `degraded` subtracting; quarantine overridden; `availability_intent` overridden; candidates reordered; a malformed store emptying a route |

---
## 10. Baseline validation remediation proposal

**Nothing is repaired here.** This is a proposal, and it begins by withdrawing a
diagnosis I published.

### What is verified

| Fact | Status |
|---|---|
| 153 suites executed in `/opt/schott-platform` at `80fe105` | **VERIFIED** |
| 125 pass, **28 fail** | **VERIFIED** |
| The full validation driver exits **1**, halting at step 24/168 (*Fabric evidence authority*) | **VERIFIED** |
| An earlier quick run halted at step 16/143 (*Generation-12 installer*) — both are first-failure halts on members of the same 28 | **VERIFIED** |
| ENG-0006-C introduced **none** of them | **VERIFIED two independent ways** |
| ENG-0006-C's report says "three pre-existing failures" | **WRONG** — it combined a 40-suite targeted sweep (2 failures) with the validator's single halt point (1) and presented the sum as complete |

**The content-independence proof stands**, and it is the conclusion that matters
for publication. (a) Baseline-worktree versus HEAD-worktree over all 28: failing
sets **byte-identical**. (b) Stash-based comparison in `/opt/schott-platform` for
three suites: identical failures at both contents.

### The diagnosis I published, withdrawn

My publication report split the 28 into "18 environment-specific, 10
reproducible", on the basis that 18 passed in a clean worktree. **That split is
not reliable.**

*VERIFIED in this increment:* **26 of the 28 suites exercise a provisioning
ceremony that hard-codes `REPOSITORY="/opt/schott-platform"`** — for example
`install-generation-6.sh`, `-12`, `-15` and `-20` all contain that literal —
while each suite computes its own root from `SCRIPT_DIR/..`. In a worktree those
two paths diverge, so the suite validates the worktree while the ceremony
operates on the main tree. **A "pass" under that mismatch is not evidence of a
clean environment**; it may be an artefact of checking one tree against another.

### The `__pycache__` hypothesis, tested and refuted

The brief asks whether ignored `__pycache__` directories explain the
environment-dependent failures. **They do not.** *VERIFIED by experiment:*

1. Fresh worktree at `80fe105`, 0 `__pycache__` directories →
   `test-capability-execution-generation6-installer.sh` **exit 0, 0 failures**.
2. Imported 87 modules across `tools.capability`, `tools.fabric`, `tools.common`
   and `tools.trust`, producing 7 `__pycache__` directories.
3. Same suite, same commit, only `__pycache__` added → **exit 0, 0 failures**.

**`__pycache__` alone does not convert a passing run into a failing one.** The
hypothesis is refuted for a representative member of the set, and
`/opt/schott-platform`'s other ignored entries — `.claude/`, `ai/.env`,
`ai/.env.bak-20260803T210703`, `backups/` — remain untested as causes.

### Proposed remediation scope

*RECOMMENDATION.* **A determination step before any repair.**

| Step | Action | Scope |
|---|---|---|
| **R1** | **Determine the cause.** Pick one failing installer suite and bisect the difference between `/opt/schott-platform` and a clean checkout **at the same path** — e.g. a clean clone placed at `/opt/schott-platform` with the current tree moved aside, under an operator-approved window. The hard-coded `REPOSITORY` makes same-path comparison the only sound method. | investigation only; no repair |
| **R2** | Classify the 28 by proven cause. Likely more than one class: the Generation-6 symptom is an object-count mismatch (`43`, expected `44`), while `test-artifact-authority` and `test-fabric-evidence-authority` fail while building nested temp fixtures. | classification only |
| **R3** | Repair the smallest class with a proven cause, one suite family per commit, each with RED-before-GREEN. | minimal |
| **R4** | Re-run the full driver and record the exit code. | verification |

**Minimal safe corrective scope:** whatever R1 proves, and nothing adjacent. If
the cause turns out to be the hard-coded `REPOSITORY` literal itself — which R1
would show by a same-path clean checkout passing — the repair is to derive the
repository root rather than hard-code it, in the ceremonies only.

### When

*RECOMMENDATION:* **after H1 and before H6.**

- **Not before H1.** H1 is purely additive, needs no store, and touches nothing
  the 28 exercise. Blocking it on an unrelated investigation delays reviewable
  work for no safety gain, and H1's acceptance criteria already require the 28 to
  be unchanged in membership — which detects any accidental interaction.
- **Before H6.** H6 is the first increment with filesystem behaviour and the
  first that would want a trustworthy full-platform run as its baseline. Entering
  it while 28 suites fail for unknown reasons means a new filesystem failure could
  hide among them.

### Release gate

*RECOMMENDATION — explicit:* **the relevant full-platform validation must exit 0
before any Health increment is merged to `main` or deployed**, unless a separately
approved, written exception names the specific suites exempted and why.

"Relevant" needs defining rather than assuming, and I propose: the full driver
exits 0, **or** every suite it would run exits 0 individually with a written
exception listing each exempted suite, its proven cause, and its remediation
ticket. **Do not declare full-platform validation green.** It is not: exit code 1.

---

## 11. Fabric integration and compatibility boundaries

*Analysis only. Nothing implemented.*

### The nine outcomes, mapped to the approved CSEL contract

*VERIFIED:* every outcome below is representable in the committed
`capability-selection` schema. Selection-level fields: `consulted`,
`adapter_outcome`, `effect`, `warning`, `evaluated_at`. Per-candidate fields:
`instance_id`, `health_state`, `health_effect`, `health_freshness`,
`envelope_id`, `envelope_version`, `warning`, `evidence_unusable_reason`.

| Outcome | `consulted` | `adapter_outcome` | `health_state` | `health_effect` | warning |
|---|---|---|---|---|---|
| Health not consulted | `false` | — | `not-consulted` | `none` | **required** |
| Consulted, no usable conclusion | `true` | `answered` | `unknown` | `none` | **required** |
| Consulted and healthy | `true` | `answered` | `healthy` | `none` | not required |
| Consulted and degraded | `true` | `answered` | `degraded` | `none` *(D7: inert in v1)* | **required** |
| Consulted and unavailable | `true` | `answered` | `unavailable` | `removed` | **required** |
| Adapter unavailable | `true` | `unavailable` | `unknown` | `none` | **required** + `evidence_unusable_reason` |
| Malformed / unverifiable evidence | `true` | `malformed` | `unknown` | `none` | **required** + `evidence_unusable_reason` |
| Stale evidence | `true` | `answered` | the prior finding, e.g. `degraded` | `none` | **required**, naming the age |
| Contradictory observations | `true` | `answered` | `unknown` | `none` | **required** (contradiction cited on the state, `review_required`) |

**Two observations.** `adapter_outcome` has a fourth value, `unreadable`, which
covers an unreadable store as distinct from an unavailable adapter — so the
contract is slightly richer than the nine cases require. And **three outcomes
share `health_state: unknown`** — no usable conclusion, adapter unavailable, and
contradiction — distinguished by `adapter_outcome` and
`evidence_unusable_reason`. That is correct rather than lossy: all three are
honestly "health has nothing to assert", and the reason they differ is a fact
about the *observer*, which is where the contract records it.

### Legacy CSEL compatibility

*VERIFIED from the committed schema:*

```yaml
health_disclosure_boundary:
  set: closed
  pre_disclosure_selection_ids: [CSEL-000001 … CSEL-000005]
  disclosure_required_from: CSEL-000006
  global_schema_version_changed: false
  legacy_record_default_meaning: forbidden
  new_write_may_join_closed_set: false
  rewrite_of_existing_records: forbidden
```

The five production records remain valid and unchanged because: identifiers come
from a monotonic sequence that **refuses rollover**, so every new identity is
strictly greater than every closed-set member and **a new write cannot join the
set**; `from_dict` refuses unknown keys but **never checks for missing ones**, so
added fields do not invalidate an older record; and the global
`schema_version` — one value shared by eight families, enforced by equality —
**does not move**. A legacy record reads as `pre-disclosure-shape`, never as
`consulted: false` and never with a default health state.

### The crossing

**H15 is the first increment that crosses from isolated Health computation into
Fabric candidate selection**, by changing what `select_candidate` writes. **H16 is
the first that changes what it decides.** Both require their own independent
approval gate; neither may be entered on the strength of ENG-0006-D.

*VERIFIED:* the hook H16 would use already exists and is inert —
`health_removals` defaults to `()`, is validated as instance identifiers, is
folded into the request digest, and is applied after `evaluate_eligibility`. It is
**not reachable from the CLI**, so no operator can currently supply health
removals even by accident. Making it reachable is part of H16, not earlier.

---

## 12. Release and deployment prerequisites

*RECOMMENDATION.* Before any Health component is merged to `main` or deployed:

1. **Full-platform validation exits 0**, or a written, separately approved
   exception naming each exempted suite (§10).
2. **H18 complete:** `/var/lib/kyri/health` created by an operator ceremony,
   `cschott:cschott 0700`, verified, containing no records.
3. **D5 unresolved means no heartbeat surface is deployed** — verified by absence,
   not by configuration.
4. **The Capability/Health barrier test passes unaltered.**
5. **Production digests unchanged** across the deployment for Fabric, Capability
   Runtime and Trust, except where an increment is specified to change them (only
   H15/H16 touch Fabric records, and then only new ones).
6. **Rollback rehearsed** for H15 and H16 specifically: disclosure and subtraction
   must be revertible without rewriting any `capability-selection` record written
   under them. Records written with disclosure stay valid after a revert — they are
   simply ahead of the boundary — so rollback is a code revert, never a record
   repair. **This must be demonstrated, not assumed.**
7. **Independent review of each crossing increment**, recorded outside the
   repository, following the ENG-0005 closure precedent.

---

## 13. Open questions requiring reviewer decisions

*UNRESOLVED. Each changes what a future increment does.*

| # | Question | Why it needs a decision |
|---|---|---|
| **Q1** | Is the first increment H1 alone, or H1–H5 bundled? | The brief suggests bundling the pure components. I recommend splitting (§6) because four independent specifications in one review is a weaker review, and the continuity rules are the subtlest part of the architecture. This is a judgement about review granularity and it is the reviewer's. |
| **Q2** | Does `tools/health/` sit beside `tools/fabric/` as a peer plane? | Implied by the architecture and by every other plane's layout, but never stated. An implementer should not choose the package root for a new plane. |
| **Q3** | Should H6's `HealthStore` override `validate()` only, or should the base `ImmutableStore.validate()` be generalised to take an identifier key? | The base reads `record.get("id")`; Fabric already overrides. Generalising would touch a shared released module used by other planes — **out of scope for ENG-0006** and listed so it is a decision rather than a silent divergence. |
| **Q4** | What is the operator-reviewed input path for envelopes? | `/etc/kyri/fabric` is the precedent (`root:cschott 0750`). ADR-0013 requires authoring and evaluating to be separate authorities but names no path. |
| **Q5** | Does `heartbeat-freshness` stay in the dimension enum with no producer? | With E2 blocked, the dimension can only be populated by an independent collector. Leaving it is harmless; the reviewer may prefer it be explicitly marked unproducible in v1. |
| **Q6** | When is the §10 release gate applied — at merge to `main`, or at deployment? | They are different moments with different risks, and the ENG-0005 precedent merges before tagging. |
| **Q7** | Does the §10 remediation (R1) need an operator window, given it may require moving `/opt/schott-platform` aside? | The hard-coded `REPOSITORY` makes same-path comparison the only sound method, and that is an operator action, not an engineering one. |

---

## 14. Recommended next implementation gate

**RECOMMENDATION: authorise ENG-0006-H1 only** — Health record models and schema
conformance, as contracted in §6.

It is the smallest increment that produces reviewable runtime code; it needs no
store, no privilege, no network and no architecture decision; every one of its
tests can fail against a wrong implementation; and it is revertible with a single
`git revert` because nothing outside `tools/health/` and two registration lines
changes.

**Explicitly not authorised by this plan:** H2 through H18; any store creation;
any heartbeat surface (D5); any Fabric change; any merge or deployment; and any
resolution of D1–D7.

**The gate after H1** should confirm three things before H2: that the H1 suite
genuinely fails against an empty implementation; that the 28 baseline failures are
unchanged in membership; and that `/var/lib/kyri/health` still does not exist.

---

## 15. Result

```
RESULT=REVIEW_REQUIRED
INCREMENT=ENG-0006-D
BRANCH=arch/eng-0006-health-runtime
STARTING_HEAD=80fe105513ed9da668e063f6963c9cb8367191b9
COMPONENTS_IDENTIFIED=21
INCREMENTS_PROPOSED=18
FIRST_IMPLEMENTATION_INCREMENT=ENG-0006-H1 (Health record models and schema conformance)
DEFERRED_DECISIONS_PRESERVED=7 (D1-D7, none resolved)
D5_RECEIVER_BLOCKED=YES (heartbeat receiver not scheduled at all)
BASELINE_FAILURES_DOCUMENTED=28 of 153; full driver exit 1
ARCHITECTURE_FILES_CHANGED=NO
RUNTIME_CODE_CHANGED=NO
HEALTH_STORE_CREATED=NO
PRODUCTION_MUTATION=NONE
MERGED=NO
PUSHED=NO
NEXT=Independent ChatGPT review
```

## Related

- [ENG-0006-C architecture reconciliation](2026-10-13-eng-0006-c-architecture-resolution.md)
- [ENG-0006-B resolution package](2026-10-13-eng-0006-b-architecture-resolution-package.md)
- [ENG-0006-A reconciliation](2026-10-12-eng-0006-a-architecture-reconciliation.md)
- [ADR-0013: The Capability Health Plane](../../../decisions/ADR-0013-capability-health-plane.md)
- [ADR-0019: The Health Condition and Hysteresis Grammar](../../../decisions/ADR-0019-health-condition-grammar.md)
- [ADR-0012: The Distributed Capability Fabric](../../../decisions/ADR-0012-distributed-capability-fabric.md)
