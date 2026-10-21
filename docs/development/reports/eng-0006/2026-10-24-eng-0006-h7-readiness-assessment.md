# ENG-0006-H7 — Implementation Readiness Assessment

**Date:** 2026-10-24
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `e47679c18ee8cb77156adea00cd0b48caaadb88a` (H6A, published)
**Scope:** C1 — human-authored envelope ingestion
**Nature:** Planning only. **No implementation, no tests, no schema change, no store, no change to `/var/lib/kyri`.**
**Recommendation:** **HOLD** — three blockers and eight questions need operator rulings. §15 states what a narrowed GO would look like.

---

## 1. Verified starting state

| Check | Result |
|---|---|
| repository / branch | `/opt/schott-platform`, `arch/eng-0006-health-runtime` |
| local HEAD | `e47679c18ee8cb77156adea00cd0b48caaadb88a` |
| remote HEAD | `e47679c18ee8cb77156adea00cd0b48caaadb88a` (`ls-remote` and tracking ref agree) |
| local vs remote | 0 ahead, 0 behind |
| worktree / index | clean; 0 untracked |
| ancestry since H5 | linear, 0 merges: `900dcea → ec8e066 → 87cc597 → e47679c` |
| `/var/lib/kyri/health` | absent |
| H7 implementation present | **none** — `tools/health/` holds exactly `__init__.py`, `records.py`, `errors.py`, `conditions.py`, `freshness.py`, `hysteresis.py`, `store.py` |

The `*authority*` test suites in `tests/` belong to the Capability, Fabric,
Artifact and Provisioning planes and predate ENG-0006. None is Health's.

---

## 2. Governing requirements, by source class

Throughout this report: **[C] committed requirement**, **[P] implementation
precedent**, **[D] proposed design decision needing a ruling**.

| # | Requirement | Source | Class |
|---|---|---|---|
| R1 | "An envelope is authored by a human. Thresholds are never learned, derived, or inferred from observed behaviour." | `operational-envelope.md:64-65` | **[C]** |
| R2 | `authored_by: human`, `threshold_source: declared-only` | CHENV schema `:37-38` | **[C]** |
| R3 | `baseline_promotion: forbidden`; "No baseline automatically becomes a threshold." | CHENV schema `:47`; `operational-envelope.md:92-93` | **[C]** |
| R4 | `violation_widens_threshold: false`; "Frequent violations cannot widen a threshold." | CHENV schema `:51`; `operational-envelope.md:94-96` | **[C]** |
| R5 | "**Envelope changes require immutable approval.** A new envelope version is a new record with an **approving identity**, not an edit." | `operational-envelope.md:97-98` | **[C]** |
| R6 | `change_requires: immutable-approval` | CHENV schema `:53` | **[C]** |
| R7 | "Human-authored envelope inputs follow the **approved-input precedent** and are **reviewed before they reach the store**, so that authoring a threshold and running the evaluator are not the same authority." | `ADR-0013:547-549`; restated `governance-boundaries.md:133` | **[C]** |
| R8 | `mutability: immutable`, `update_methods: none`, `delete_methods: none`, `supersession: new-record-only` | CHENV schema `:32-35` | **[C]** |
| R9 | `supersession_rewrites_prior_evaluations: false` | CHENV schema `:65` | **[C]** |
| R10 | `may_modify_trust_state: false`, `may_execute: false` | CHENV schema `:75-76` | **[C]** |
| R11 | Trust reads or writes Health **"Never**, in either direction" | `ADR-0013:545` | **[C]** |
| R12 | Health writes its own store **Yes**; reads Fabric/Trust only through read-only adapters | `ADR-0013:541-542` | **[C]** |
| R13 | All four hysteresis members required; "an envelope omitting either continuity member is refused" | CHENV schema `:207-213` | **[C]** |
| R14 | Conditions structured; expression strings forbidden; five operators; decimal-string values | CHENV schema `:135-155` | **[C]** |
| R15 | `unit_mismatch: refuse`, `unit_conversion: forbidden`, one unit per dimension | CHENV schema `:180-181` | **[C]** |
| R16 | `absent_envelope_means: unmonitored`; `absent_threshold_means: insufficient-policy` | CHENV schema `:58-60, 71` | **[C]** |
| R17 | C1 spec: purpose, upstream A1/A3/A5/B1, permissions, failure modes, required tests | ENG-0006-D `:204-212` | **[C]** |
| R18 | D1 deferral — **H7 "envelope ingestion must refuse a `publication` block"** | ENG-0006-D `:455`, `:563` | **[C]** |
| R19 | The production Health root is created by **H18**, not by a library call | ENG-0006-D `:504`, `:746`; H6 report §4 | **[C]** |
| R20 | Approved-input shape: a bare `name` plus an `--approved-directory`, resolved then containment-checked, never a caller-chosen path | `tools/trust/root_authority.py:60-104`; `tools/trust/cli.py:70`; `tools/fabric/cli.py:121`; `tools/observation/cli.py:55`; `tools/collectors/cli.py:67`; `tools/collectors/remote/target.py:315` | **[P]** |
| R21 | "Kyri may persist a declaration that an external root exists, and Kyri must not establish the external identity itself. This module records **what a human verified out of band**. It does not verify, does not resolve, and does not guess." | `tools/trust/root_authority.py:1-8` | **[P]** |

**ENG-0006-D `:204-212`, C1, verbatim on the points that bind H7:**

> **Purpose:** accept an operator-authored envelope.
> **Spec:** CHENV `authored_by: human`, `threshold_source: declared-only`, `change_requires: immutable-approval`, `baseline_promotion: forbidden`, `violation_widens_threshold: false`; ADR-0019 required members.
> **Upstream:** A1, A3, A5, B1.
> **Permissions:** reads an operator-reviewed input location; writes the Health store. **Authoring a threshold and running the evaluator must not be the same authority.**
> **Failure:** refuse a learned/derived/auto threshold field; refuse missing continuity members; refuse a unit mismatch.
> **Tests:** every forbidden envelope field refused; missing `max_gap_seconds` or `min_samples` refused; no-envelope → `unmonitored`; partial envelope → `insufficient-policy` per metric.
> **Deferred:** **D1** (no `publication` block may be added). **Production-safe:** yes (fixtures).

---

## 3. C1 scope boundary

### 3.1 A scope divergence that needs a ruling first — Q-H7-1

**ENG-0006-D `:389` assigns H7 both components:**

> | **H7** | Envelope ingestion, versioning, supersession | **C1, C2** | no | standard |

The assignment brief assigns **C1 only** and states "Do not implement C2 early."
The committed plan and the brief therefore disagree about H7's scope, in the
same way they did at H6 over B2 (Q-H6-2), which was resolved by an explicit
operator ruling superseding the earlier instruction.

I have assessed **C1 only**, as instructed, and §9 sets out the C1/C2 boundary.
The divergence is recorded rather than silently resolved, because ENG-0006-D is
committed authority and a reviewer should decide whether H7 is being
deliberately narrowed (as B2 was deliberately *added*) or whether C2 follows in
an H7B.

### 3.2 What C1 is

Accepting one operator-authored envelope from a reviewed input location,
validating it, persisting it as an immutable CHENV record, and reporting the
result. **Ingestion only** — C1 concludes nothing, evaluates nothing, and
grants no authority (R10).

### 3.3 What C1 is explicitly not

| Out of scope | Why |
|---|---|
| supersession and versioning behaviour | C2 (§9) |
| evaluating the envelope against observations | A3/A4/A5 and D1c; and R7 forbids authoring and evaluating being one authority |
| deriving `unmonitored` or `insufficient-policy` **states** | those are **D1c/H10** outcomes. C1's listed "tests" for them (`no-envelope → unmonitored`) are *consequences* of C1's absence, assertable only once H10 exists — see §12 |
| creating `/var/lib/kyri/health` | H18 (R19) |
| any `publication` block | D1 (R18) |
| a new authority system | prohibited by the brief; R11/R12 bound what Health may touch |

---

## 4. Existing reusable implementation

**The headline finding: almost all of C1's declared validation already exists,
and it is in A1 — not in A3 or A5.**

`records.parse()` (`records.py:806-842`) is a **closed field set** over the
committed schema, and it validates every dimension member structurally:

| Validator | Location | What it already enforces |
|---|---|---|
| `parse()` field gate | `:819-832` | forbidden fields refused **by name** (`FORBIDDEN_FIELD`) before unknown ones; any undeclared field refused (`UNKNOWN_FIELD`); every required field required |
| `_validate_envelope` | `:517-531` | identifier, `envelope_version ≥ 1`, subject type from a closed pair, `subject_id` text, dimensions, `evaluation` from a closed set, `provenance` is a mapping |
| `_dimension_entry` | `:336-369` | the dimension name is declared; the entry is **exactly** the seven required members, no more and no fewer; the `dimension` member equals its key; **`unit` equals `DIMENSION_UNITS[dimension]`** (R15); `freshness_policy_seconds` null-permitted and never defaulted (R16) |
| `_condition` | `:279-295` | exactly `{operator, value}` — so an expression string is structurally impossible (R14); operator from the closed five; value is an exact decimal string |
| `_aggregation` | `:298-321` | `instant` takes no parameter; `windowed_count` requires exactly `kind`+`window_seconds`+`min_samples`, each ≥ 1 |
| `_hysteresis` | `:324-333` | `kind` from the closed one (`duration`); **exactly** `kind`+`seconds`+`max_gap_seconds`+`min_samples`, each ≥ 1 — so a missing continuity member is already refused (R13) |
| `_identifier` | `:168-178` | fullmatch against the schema pattern (H6A) |
| `HealthStore` | `store.py` | six families, widths, write-once `os.link`, no update/delete, 0700/0600, root and path vetting, `validate()` |

**A3/A4/A5 must NOT be invoked at ingestion.** All three public entry points
require `observations` *and* `evaluated_at`:

```
evaluate_condition(*, dimension, unit, condition, aggregation,
                   freshness_policy_seconds, observations, evaluated_at)
evaluate_freshness(*, dimension, freshness_policy_seconds, observations, evaluated_at, ...)
evaluate_hysteresis(*, dimension, unit, condition, hysteresis, ..., observations, evaluated_at)
```

At ingestion there are no observations and no evaluation instant. Calling them
would require **fabricating** both, and the result would be the ingestion path
evaluating the policy it is admitting — precisely what R7 forbids. ENG-0006-D
lists A3 and A5 as C1 **upstream** because C1 must accept only envelopes those
evaluators can later consume; that dependency is satisfied by the *structural*
validators above, which share the same constants (`CONDITION_OPERATORS`,
`AGGREGATIONS`, `HYSTERESIS_KINDS`, `DIMENSION_UNITS`).

**So what H7 actually adds is small:** read from an approved location, establish
authority, call `parse()`, call `HealthStore.write_record()`, read back, and
return a result. Essentially no new validation logic.

---

## 5. Human authority and approval — the central gap

### 5.1 What establishes "human-authored"?

**Nothing in the record does.** `authored_by: human` and
`threshold_source: declared-only` (R2) are **schema-level constraint
declarations about the family**, in the same block as `mutability` and
`may_execute` — they are *not* record fields. CHENV's field sets are:

- **required:** `envelope_id`, `envelope_version`, `subject_type`, `subject_id`, `dimensions`, `evaluation`, `provenance`
- **optional:** `description`, `review_due_at`, `supersedes`, `superseded_by`, `notes`

There is **no** `authored_by`, `approving_identity`, `approved_by`,
`approval_id`, `signature`, or `digest` field. The only candidate carrier is
`provenance`, and `_validate_envelope` validates it as `_mapping` **only** —
any mapping with any keys passes, including an empty one.

So "human-authored" is established **structurally, by where the input came
from**, not by anything inside the record. That is exactly what R7 says:
envelopes "follow the approved-input precedent and are reviewed before they
reach the store."

### 5.2 Which existing mechanism can authenticate and authorize the operator?

**The approved-input precedent (R20), and nothing stronger.** Six call sites
implement it identically — `tools/trust/root_authority.py`,
`tools/trust/cli.py`, `tools/fabric/cli.py`, `tools/observation/cli.py`,
`tools/collectors/cli.py`, `tools/collectors/remote/target.py` — all via
`tools/common/containment.py:contained_path`, which resolves both sides and
requires the target to be **strictly beneath** the approved directory, judging
a symlink by where it lands rather than by its name.

The authority model is explicit in `root_authority.py:1-8` (R21): the platform
"records what a human verified **out of band**. It does not verify, does not
resolve, and does not guess." There is **no interactive prompt, no
environment-variable identity, and no implicit current user** — by design.

**So the platform's committed notion of operator authority for declared input
is: a filesystem location the operator controls, plus a recorded declaration of
out-of-band verification.**

### 5.3 This collides head-on with a stated invariant — Q-H7-3

The brief states: *"Do not treat possession of filesystem write access as
sufficient evidence of operator authorization."*

But the committed precedent's authority **rests on exactly that**: whoever can
write into the approved directory is treated as the authoring operator. There
is no second factor.

These cannot both hold. Either
(a) C1 follows the committed precedent (R7's literal instruction) and the
invariant is understood as "do not treat write access *to the Health store*
as authorization" — a reading the precedent satisfies, since the approved
directory is a separate, operator-controlled location; or
(b) the invariant requires a stronger mechanism, which **does not exist** and
would have to be designed — and the brief also forbids inventing an approval
protocol.

**I cannot resolve this, and will not invent an approval protocol. Ruling
required.**

### 5.4 What immutable approval evidence is required, and where would it live?

R5/R6 require it: "A new envelope version is a new record with an **approving
identity**." But:

- **CHENV declares no field to carry it.** Adding one is a schema amendment,
  which this assignment forbids.
- **It cannot be stored in the Trust store.** R11 — "Trust reads or writes
  Health **Never, in either direction**." Writing Health approval evidence into
  Trust storage is a Health→Trust write and is prohibited outright.
- **`provenance` is the only existing carrier**, and it is entirely
  unvalidated. Putting an approving identity in an unconstrained mapping means
  nothing is enforced: an envelope with `provenance: {}` passes today.

**Q-H7-2.** Is an approving identity required for the **first** envelope
(version 1)? R5's wording is about *changes* — "Envelope **changes** require
immutable approval. A new envelope **version** is a new record with an
approving identity." A first envelope is arguably not a change. If an approving
identity *is* required at v1, H7 is blocked on a schema amendment.

### 5.5 Is approval bound to the exact envelope bytes? Can replay or
modification be detected?

**No, and no.** There is no committed mechanism that binds an approval to a
digest of the envelope bytes. Consequently:

- A **modified approved payload** cannot be detected — nothing records what was
  approved.
- A **replayed approval** cannot be detected — there is no nonce, no
  one-time-use record, and no binding to a specific envelope.

Digest machinery *does* exist in the platform —
`tools/capability/execution/canonical_json.py`,
`tools/platform_model/evidence_fingerprint.py`, `tools/fabric/request_identity.py`,
and ~45 other modules use `hashlib` — but **every one of them is in a plane
Health may not import** (Capability, Fabric, Trust, Provisioning, Observation,
Integrity, Collectors). None is in `tools/common`.

**Q-H7-4.** Is byte-binding required for C1? If yes, from where? A Health-local
digest helper, a new `tools/common` primitive, or a module-scoped exception to
an existing plane — each is a different architectural decision, and the
cheapest (Health-local `hashlib`) still needs a new import exception (§11).

### 5.6 Does the platform support this workflow today?

| Capability | Status |
|---|---|
| read a declared input from an operator-controlled location, containment-checked | **Yes** — R20, six precedents |
| refuse credential material in the input | **Yes** — `reject_forbidden_keys` precedent, though it is in `tools/trust` |
| validate the envelope in full against schema and condition grammar | **Yes** — A1, §4 |
| persist immutably, write-once, no update/delete | **Yes** — B1/B2, H6 |
| record a declaration of out-of-band human verification | **Yes** as a *pattern*, **No** as a CHENV field |
| authenticate the submitting operator as an identity | **No** — by design (R21) |
| bind approval to exact envelope bytes | **No** |
| detect replayed or modified approval | **No** |

---

## 6. Field-by-field CHENV validation matrix

**Legend.** *Enforced* = already enforced by committed code, with the location.
*H7 adds* = what C1 would add. Nothing in this matrix requires new validation
logic except where marked **GAP**.

### 6.1 Record-level fields

| Field | Class | Enforced today | By | H7 adds | Gap |
|---|---|---|---|---|---|
| `envelope_id` | required | fullmatch `^CHENV-[0-9]{4}$`; store agrees | `_identifier`; `store.path_for` | allocation via `allocate_id` | — |
| `envelope_version` | required | integer ≥ 1 | `_whole` | — | no check that v1 is the first, or that vN+1 follows vN → **C2** |
| `subject_type` | required | `capability-instance` \| `capability-host`; package refused | `_member` + `SUBJECT_TYPES` | — | — |
| `subject_id` | required | non-empty text **only** | `_text` | — | **GAP**: not pattern-checked, and existence is not verified (H2 asserts nothing about subject existence). A subject that does not exist is accepted |
| `dimensions` | required | per-entry, see 6.2 | `_dimensions` / `_dimension_entry` | — | — |
| `evaluation` | required | `worst-dimension-wins` only | `_member` + `EVALUATIONS` | — | — |
| `provenance` | required | **is a mapping** — nothing more | `_mapping` | — | **GAP**: no required keys. `provenance: {}` passes. This is the only candidate carrier for authorship/approval (§5.4) |
| `description` | optional | text if present | `_text` | — | — |
| `review_due_at` | optional | offset-aware instant if present | `_instant` | — | — |
| `supersedes` | optional | **text** if present | `_text` | — | **GAP**: not validated as a CHENV identifier, and the referenced record's existence is not checked → **C2** |
| `superseded_by` | optional | **text** if present | `_text` | — | **GAP**: same; also, setting it on a *new* record would be an edit of the prior one if ever honoured → **C2** |
| `notes` | optional | text if present | `_text` | — | — |
| any other field | forbidden | refused `UNKNOWN_FIELD` | `parse():828` | — | includes `publication` (R18) — see Q-H7-8 |

### 6.2 Dimension-entry members (exactly these seven; more or fewer refused)

| Member | Enforced today | By | Gap |
|---|---|---|---|
| `dimension` | from the closed 13; **must equal its own map key** | `_member` + `DIMENSIONS`; `:356-358` | — |
| `unit` | **must equal `DIMENSION_UNITS[dimension]`** (R15) | `:360-361` | — |
| `entry_condition` | exactly `{operator, value}`; operator from five; value an exact decimal string | `_condition` | — |
| `exit_condition` | identical rules | `_condition` | **GAP**: no check that exit is *weaker* than entry — nothing forbids an exit condition that can never be met. Not a declared requirement, so not an H7 defect |
| `hysteresis` | `kind: duration`; **all four** members, each ≥ 1 (R13) | `_hysteresis` | — |
| `freshness_policy_seconds` | integer ≥ 1, or **null** (never defaulted) (R16) | `:365-368` | — |
| `aggregation` | `instant` takes no parameter; `windowed_count` requires exactly `window_seconds`+`min_samples`, each ≥ 1 | `_aggregation` | — |

### 6.3 The eleven forbidden fields — all enforced by name today

`learned_threshold`, `auto_threshold`, `baseline_threshold`,
`derived_threshold`, `anomaly_model`, `anomaly_score`, `forecast`,
`predicted_limit`, `health_score`, `trust_state`, `command`
— refused with `FORBIDDEN_FIELD` at `parse():825-827`, **before** the unknown-field
check, so each is a named architectural refusal rather than "unrecognised".
This is what enforces R1, R3, R4 and R10 at ingestion.

**Semantic consistency check.** Unit, aggregation, threshold representation and
continuity are enforced **consistently**, because ingestion-time validation and
evaluation-time validation read the **same module constants** —
`CONDITION_OPERATORS`, `AGGREGATIONS`, `HYSTERESIS_KINDS`, `DIMENSION_UNITS`,
`DIMENSIONS` all live in `records.py` and are imported by `conditions.py`,
`freshness.py` and `hysteresis.py`. There is no second copy to drift. H6A
additionally pinned `records.PATTERNS` to the committed schema per family.

---

## 7. Proposed ingestion data flow — [D], for approval

```
  operator writes envelope YAML into an approved directory   (outside the repo,
                                                              operator-owned)
        │
        │  H7 is given: a bare file NAME + the approved directory
        ▼
  1. contained_path(approved_directory, name)          -- refuse if it resolves
                                                          outside, or is not a file
        ▼
  2. yaml.safe_load                                    -- refuse non-mapping,
                                                          refuse YAML errors
        ▼
  3. refuse credential-shaped keys                     -- precedent: trust's
                                                          reject_forbidden_keys
        ▼
  4. AUTHORITY CHECK                                   -- *** UNDEFINED ***
                                                          see §5, Q-H7-2/3/4
        ▼
  5. records.parse("capability-health-envelope", data) -- the whole of §6
        ▼
  6. refuse if envelope_version != 1                   -- C1-only guard (§9)
        ▼
  7. store.allocate_id(...)  /  or honour the authored envelope_id   (Q-H7-6)
        ▼
  8. store.write_record(...)                           -- write-once; refuses an
                                                          existing identifier
        ▼
  9. readback: store.read_record(...) and compare to the parsed record
        ▼
 10. return an ingestion RESULT object                 -- no record written for
                                                          a refusal
```

Step 4 is a hole in the middle of the flow, not an implementation detail. Steps
1–3 and 5–10 are all reusable precedent or committed code; step 4 is the only
part with no committed mechanism.

### 7.1 Interface — Q-H7-5

**ENG-0006-D names no interface for Health.** Its only CLI statements are
*negative*: the Fabric health hook is "**not reachable from the CLI**"
(`:106`), "no mutation path in the CLI" (`:309`), and "**not reachable from the
CLI**, so no operator can currently supply health" (`:735`).

The minimum required interface is a **library function**:

```python
def ingest_envelope(store, *, name, approved_directory, authority) -> IngestResult
```

A CLI (`tools/health/cli.py`, following `tools/trust/cli.py` and
`tools/fabric/cli.py`) is what the approved-input precedent actually looks like
in every one of its six instances, and is how an operator would supply
`--approved-directory`. But the Health import guard asserts that no Health
module declares an interpreter line and that the package has **no
`__main__.py`**, so a CLI would be invoked as `python3 -m tools.health.cli`.

**Recommendation: library-only for H7.** It is the minimum, it satisfies C1,
and it keeps the operator-facing surface a separate, separately-reviewed
decision. **No network service, daemon, or background writer** — and none is
needed, which is consistent with D1c's `background_writer: none` and
`evaluation_trigger: explicitly-invoked`.

**Caller must provide:** the store instance, the input name, the approved
directory, and whatever the §5 ruling defines as authority context.
**Failure behaviour when identity or approval is unavailable: refuse, writing
nothing.** Fail-closed, matching LiteLLM's documented posture and H6's store.

---

## 8. Persistence and failure semantics

All of this reuses H6; **no second persistence layer.**

| Question | Answer | Source |
|---|---|---|
| How does H7 obtain a store? | **Injected by the caller.** `HealthStore` requires an explicit root and refuses to default one | `store.py:__init__`; H6 §4 |
| Who controls the root? | The operator. H6 **refuses to provision** `/var/lib/kyri/health`; H18 creates it (R19). Until then H7 is fixture-only — **Q-H7-6** | H6 §4 |
| Identifier allocation | `allocate_id("capability-health-envelope")` → flock'd, monotonic, 4-digit, skips an occupied name, refuses at `CHENV-9999` rather than rolling over | `immutable_store.py:141-181`; H6 §2 |
| Atomic write | `write_record` → `write_atomic`: temp sibling created with **O_EXCL**, `fsync`, then `os.link` to the final name. `link` fails if the destination exists, which makes committing and refusing an overwrite the **same atomic operation** | `immutable_store.py:183-234` |
| Readback verification | `store.read_record(kind, identifier)` and compare against the parsed record's `to_dict()`. **Not yet implemented anywhere** — this is H7's one genuinely new mechanism | — |
| Allocation succeeds, write fails | The sequence **stays advanced**; the identifier is consumed and never reused. H6 asserts this ("a refused write leaves the sequence advanced"). A gap in the identifier series is the correct, auditable outcome — reuse would be worse | H6 suite |
| Duplicate submission | Two paths: (a) the same `envelope_id` → `write_atomic` refuses, "already exists and is immutable"; (b) the same *content* under a new identifier → **not detected**. Content-level idempotency has no committed requirement — **Q-H7-7** |
| Partial vs committed | A crash between temp and link leaves `.CHENV-NNNN.tmp`. `HealthStore.validate()` **reports** it and repairs nothing; a subsequent write to the same name **refuses** rather than truncating it (O_EXCL). So partial submissions are distinguishable and are never mistaken for records | H6 §4; store suite |

---

## 9. C1 / C2 separation

| Behaviour | C1 | C2 |
|---|---|---|
| accept and persist a first envelope | **yes** | — |
| validate `envelope_version` is an integer ≥ 1 | yes (A1 already) | — |
| require `envelope_version == 1` | **proposed C1 guard** [D] | relaxed by C2 |
| `supersedes` / `superseded_by` as *validated CHENV references* | no | **yes** |
| refuse an edit of an existing record | yes — structural, via `write_atomic` | yes |
| chain integrity (vN+1 supersedes vN; no forks; prior exists) | no | **yes** |
| `supersession_rewrites_prior_evaluations: false` proven by worked example 7 | no | **yes** (ENG-0006-D `:217`) |
| approving identity for a *replacement* | no | **yes** — and blocked on Q-H7-2 |

**Can H7 safely accept a first envelope without C2? Yes — with one added
guard.** The reasoning:

- R8 makes editing structurally impossible: `write_atomic` refuses an existing
  name, and the store has no update or delete method at all.
- A second envelope for the same subject at version 1 would need a *different*
  `CHENV-NNNN`, and nothing in C1 validates cross-record relationships — so
  without a guard, C1 would silently admit an unordered pile of
  same-subject envelopes, which is C2's territory entered by accident.
- Therefore C1 should **refuse `envelope_version != 1`** and **refuse any
  envelope carrying `supersedes` or `superseded_by`**. Both refusals keep C1
  strictly inside its boundary and make the C2 work visible rather than
  implicit. This is proposed [D], not committed.

**How is an unauthorized replacement refused in C1?** By the version guard
above, not by an authority check — C1 has no authority mechanism (§5). This is
why C1 must refuse *all* replacements rather than authorize some.

**What evidence is required before a later version?** R5: "a new record with an
approving identity." That field does not exist (§5.4). **C2 is blocked on
Q-H7-2 regardless of C1.**

---

## 10. Security threat analysis

| # | Threat | Assessment |
|---|---|---|
| T1 | A malformed envelope influences the Fabric | **No.** `tools/fabric/selection.py` takes `health_removals` as a parameter and ENG-0006-D `:735` records it is "not reachable from the CLI, so no operator can currently supply health". AC 25 (20 assertions, `test-fabric-runtime.sh`) proves the Fabric functions with Health **unimportable**. C1 writes records; nothing reads them into the Fabric yet |
| T2 | A subject submits its own thresholds | **Not prevented by anything in Health.** The authority boundary is the approved directory's filesystem permissions. If a subject can write there, it authors its own policy — and this is the sharpest form of Q-H7-3. R7's "authoring a threshold and running the evaluator are not the same authority" is about *separation of stages*, not about authenticating the author |
| T3 | The ingestion path writes outside Health storage | **No.** `HealthStore` refuses a symlinked root, a root inside `/var/lib/kyri/fabric` or `/var/lib/kyri/trust`, provisioning the production root, a symlinked record directory or path, and any identifier that is not a fullmatch (so containment is structural). H6A proved the scope of the import permission. `contained_path` additionally confines the *input* side |
| T4 | Imported data impersonates operator policy | **Yes, within the trust model.** Any well-formed YAML in the approved directory *is* operator policy as far as the platform can tell. R21 is explicit that the platform "does not verify, does not resolve, and does not guess." This is a property of the committed design, not a defect H7 introduces — but it is why Q-H7-3/Q-H7-4 matter |
| T5 | Are filesystem permissions sufficient to prevent cross-plane writes? | **They are not the mechanism, and should not be relied on as one.** ADR-0013 `:534-537` says the separation "is the mechanism, not a convention… Discipline does not survive a bug." In practice H7 is prevented from cross-plane writes by **three** layers: the static import guard (no Trust/Fabric import is possible), `HealthStore`'s refusal of foreign-plane roots, and 0700 directory modes. Modes alone would be insufficient — the first two are the real barriers |
| T6 | A compromised caller passes a hostile store | Partly mitigated: the store refuses repository roots, symlinked roots, foreign-plane roots and the production root. A caller may still pass *any other* writable path, because an explicit root is the committed design (H6). The caller is trusted to name the root; it is not trusted to make the store write outside it |
| T7 | A compromised caller fabricates authority context | **Unmitigated, by construction.** Whatever §5's ruling defines as authority context, a compromised in-process caller can synthesise it. Only byte-bound external approval (Q-H7-4) would change this |
| T8 | Ingestion grants execution authority or changes eligibility | **No.** `may_execute: false`, `may_modify_trust_state: false` (R10); `command` is a forbidden field; `trust_state` is a forbidden field. C1 returns a result object and writes one record |
| T9 | Replay of a previously approved envelope | **Undetectable** (§5.5). Mitigated only incidentally: a replay carrying the same `envelope_id` is refused as immutable, but a replay under a fresh identifier is accepted |

---

## 11. Import-boundary implications

H6A made the guard express **module-scoped** permissions as `file:module`
pairs, pinned by exact content, shape, module half and file half. The current
authorised set is exactly:

```
HEALTH_PERMITTED_PLANE_IMPORTS=("tools/health/store.py:tools.common.immutable_store")
HEALTH_STORAGE_IMPORT_EXCEPTION="tools/health/store.py:yaml"
HEALTH_STORAGE_NAME_EXCEPTIONS=("tools/health/store.py")
```

**H7 would require new exceptions. All of them can remain module-scoped** —
this is precisely the capability H6A added, and it is the direct answer to
§5.F's last question.

| Needed by H7 | Exception | Narrowest form | Justification |
|---|---|---|---|
| read the approved input file | `yaml` | `tools/health/ingest.py:yaml` | the serialiser exception already exists as a file/module pair for `store.py`; this adds a second pair, not a wider rule |
| containment-check the input path | `tools.common.containment` | `tools/health/ingest.py:tools.common.containment` | the shared primitive behind all six approved-input precedents (R20). **Narrower than `tools.common`** — the guard matches on exact name or dotted prefix, so naming the module admits only it |
| byte-binding, **if** Q-H7-4 requires it | `hashlib` | `tools/health/ingest.py:hashlib` | `hashlib` is **not** currently in the forbidden list (`socket subprocess requests urllib http asyncio threading multiprocessing sqlite3 yaml`), so **no exception would be needed — and that is itself a finding**: a Health module could import `hashlib` today unnoticed |
| the new module itself | module allowlist | add `tools/health/ingest.py` as the **eighth** entry in the four closed allowlists | one name per increment, as H3A/H4/H6 each did |

**Preserved unchanged:** every H4B prohibition (`__import__`, `import_module`,
`eval`, `exec`, `compile`, `builtins`, `__builtins__`, `globals`, `locals`,
`vars` as Names; four as attributes), the Trust/Fabric/Capability/collectors
refusals, and the per-module storage-name enumeration. H6A's battery already
tests twelve prohibitions against two modules; H7 would extend the victim list.

**A guard-maintenance note:** H6A §7 flagged that the fixture battery's victim
list (`__init__ records errors conditions freshness hysteresis`) is a second
place to update when a module is added. H7 adding `ingest.py` is the first
occasion that matters.

---

## 12. RED/GREEN test plan

Every row names its governing requirement and the component expected to
enforce it. **"Implementable now" is stated honestly**: a test whose authority
mechanism does not exist is marked **NO**, per the brief's instruction.

### 12.1 Implementable now — validation and persistence

| # | Test | Governing req. | Enforced by | RED before |
|---|---|---|---|---|
| 1 | a valid human-authored envelope is accepted and persisted | R17 | `ingest` + A1 + B1 | the module does not exist |
| 2 | each of the 7 required fields, omitted in turn, refuses `MISSING_REQUIRED_FIELD` | R17 | `parse():830` | — (A1 already; asserted at the ingestion boundary) |
| 3 | each of the 11 forbidden fields refuses `FORBIDDEN_FIELD` **by name** | R1, R3, R4, R10 | `parse():825` | — |
| 4 | a learned/derived/auto/baseline threshold field refuses | R1, R3 | `parse():825` | — |
| 5 | automatic baseline promotion: `baseline_threshold` and `anomaly_model` refuse; no code path adjusts a value | R3 | `parse()`; absence of any mutation path | — |
| 6 | threshold widening: `violation_widens_threshold` is `false` in the schema and no ingestion path rewrites a prior record | R4, R8 | `write_atomic` (no update method exists) | — |
| 7 | a missing `max_gap_seconds` or `min_samples` refuses | R13 | `_hysteresis` | — |
| 8 | an unsupported hysteresis kind (`occurrences`, `count`) refuses | R13 | `_hysteresis` + `HYSTERESIS_KINDS` | — |
| 9 | an invalid condition operator (`ne`, `between`, `~=`) refuses | R14 | `_condition` + `CONDITION_OPERATORS` | — |
| 10 | a condition expression **string** refuses | R14 | `_condition` (closed `{operator, value}`) | — |
| 11 | an invalid decimal threshold (`"1,5"`, `"1e"`, `"NaN"`, `0.1` as a float) refuses | R14 | `_decimal_text` | — |
| 12 | a unit mismatch (`latency: seconds`) refuses `UNIT_MISMATCH` | R15 | `_dimension_entry:360` | — |
| 13 | an aggregation mismatch (`instant` with `window_seconds`; `windowed_count` without `min_samples`) refuses | R14 | `_aggregation` | — |
| 14 | an undeclared dimension, and a `dimension` member disagreeing with its key, refuse | R15 | `_dimension_entry` | — |
| 15 | a `publication` block refuses | **R18 (D1)** | `parse():828` as `UNKNOWN_FIELD` — see Q-H7-8 | — |
| 16 | a duplicate `envelope_id` refuses as immutable, and the stored bytes are unchanged | R8 | `write_atomic` | — |
| 17 | a partial write (`.CHENV-NNNN.tmp` planted) refuses and is **reported** by `validate()`, never truncated | R8 | `write_atomic` O_EXCL; `validate()` | — |
| 18 | a failed readback refuses and the discrepancy is reported | R17 | **new in H7** | the mechanism does not exist |
| 19 | a repository root is refused; a fixture root needs an explicit opt-in | H6 | `HealthStore.__init__` | — |
| 20 | a cross-plane write attempt (root at/inside the Fabric or Trust store) refuses | R11, R12 | `HealthStore._vetted_root` | — |
| 21 | an import-boundary violation: the approved imports moved into another Health module refuse | H6A | `test-capability-health.sh` battery | — |
| 22 | ingestion grants no execution authority: `command`/`trust_state` refuse; the result object exposes no action | R10 | `parse()`; result shape | — |
| 23 | no production mutation: `/var/lib/kyri/health` is absent before and after; provisioning it refuses | R19 | `HealthStore._vetted_root` | — |
| 24 | an input path escaping the approved directory (`../`, absolute, symlink out) refuses | R7, R20 | `contained_path` | the ingestion module does not exist |
| 25 | `envelope_version != 1`, or `supersedes`/`superseded_by` present, refuses | §9 [D] | **new in H7** | needs the Q-H7-1 ruling |

Rows 2–14, 16, 17, 19, 20 largely re-assert A1/B1 behaviour **at the ingestion
boundary**. That is deliberate and is the H3A precedent: a boundary test proves
the new entry point actually routes through the validator, which asserting on
`parse()` alone does not.

### 12.2 NOT implementable until an authority mechanism is ruled on

| # | Test | Blocked on | Why |
|---|---|---|---|
| 26 | missing operator authority refuses | **Q-H7-2/3** | no committed mechanism defines what authority *is*, so there is nothing to omit |
| 27 | an invalid approval refuses | **Q-H7-2** | no approval object, no field to carry one, no validity rule |
| 28 | a modified approved payload refuses | **Q-H7-4** | requires byte-binding; nothing records what was approved |
| 29 | a replayed approval refuses | **Q-H7-4** | requires a nonce or single-use record; neither exists |
| 30 | an unauthorized replacement refuses | **Q-H7-1/2** | C1 can refuse *all* replacements (row 25); refusing an *unauthorized* one requires distinguishing authorized ones, which is C2 + Q-H7-2 |

**I am not claiming rows 26–30 are implementable, and I will not stub them.**
A test that asserts a refusal produced by the absence of a feature would pass
for the wrong reason and would have to be rewritten when the real mechanism
arrives — the H4A lesson about incidental exceptions as evidence.

### 12.3 Tests ENG-0006-D lists under C1 that belong to H10

ENG-0006-D `:211` lists `no-envelope → unmonitored` and
`partial envelope → insufficient-policy per metric` as C1 tests. Both are
**derivation** outcomes (`absent_envelope_means: unmonitored`,
`absent_threshold_means: insufficient-policy`) and are produced by **D1c/H10**,
which does not exist. At C1 they are assertable only as *schema* facts, not as
behaviour. Recorded so the H7 report does not appear to skip two listed tests.

---

## 13. Dependencies and blockers

| Dependency | Classification |
|---|---|
| A1 — record models, closed field set, condition/aggregation/hysteresis structural validation | **Implemented and verified** (819 assertions; H6A pinned patterns to the schema) |
| A2 — subject binding | **Implemented and verified** (87 assertions) |
| A3 — condition grammar evaluator | **Not required for H7** — needs observations; invoking it would breach R7 (§4) |
| A4 — freshness evaluator | **Not required for H7** — same |
| A5 — hysteresis evaluator | **Not required for H7** — same; its *constants* are shared through A1 |
| B1/B2 — `HealthStore`, allocation, write-once, validate | **Implemented and verified** (210 assertions) |
| `tools/common/containment.contained_path` | **Implemented and verified** — but **not importable by Health** without a new module-scoped exception (§11) |
| the approved-input precedent | **Implemented but insufficient** — it establishes *where* input came from, not *who* authored it, and cannot detect modification or replay (§5.5) |
| operator identity / authentication | **Documented but unimplemented** — R21 states the platform deliberately does not establish identity |
| immutable approval evidence on CHENV | **Undeclared architectural decision** — R5/R6 require it; no field exists to carry it; Trust storage is prohibited (R11). **BLOCKER for C2; possibly for C1** |
| byte-binding of approval to envelope content | **Undeclared architectural decision** — no committed mechanism; all digest code is in planes Health may not import. **BLOCKER if required** |
| readback verification | **Not implemented** — new in H7, straightforward over `read_record` |
| production Health store root | **Documented but unimplemented** — H18. H7 is fixture-only until then (R19) |
| H10 derivation | **Not required for H7** — but two of C1's listed tests depend on it (§12.3) |

### Blockers

1. **B-1 — no approving-identity field.** R5/R6 require immutable approval with
   an approving identity; CHENV declares no field for it and Trust storage is
   prohibited. Blocks C2 outright; blocks C1 **if** v1 needs one (Q-H7-2).
2. **B-2 — the authority invariant contradicts the committed precedent.** The
   brief forbids treating filesystem write access as authorization; the
   committed approved-input precedent rests on exactly that (Q-H7-3).
3. **B-3 — no byte-binding, so modification and replay are undetectable**, yet
   the test plan requires covering both (Q-H7-4).

---

## 14. Open architecture questions requiring operator rulings

- **Q-H7-1 — H7's scope.** ENG-0006-D `:389` assigns H7 **C1 and C2**; the
  brief assigns C1 only. Which governs? If C1 only, does C2 become H7B?
- **Q-H7-2 — the approving identity.** Is one required on a **first** envelope?
  If yes, which field carries it? `provenance` is unvalidated; adding a field is
  a schema amendment this assignment forbids. (R5, R6)
- **Q-H7-3 — the authority model.** The brief says filesystem write access is
  not sufficient evidence of authorization; the committed precedent (R7, R20,
  R21) has nothing else. Is C1 authorised to follow the precedent, or must a
  stronger mechanism be designed first?
- **Q-H7-4 — byte-binding.** Is approval required to be bound to the exact
  envelope bytes for C1? If yes, from where — a Health-local `hashlib` helper,
  a new `tools/common` primitive, or a module-scoped exception to an existing
  plane's canonical-JSON code?
- **Q-H7-5 — the interface.** Library-only (my recommendation), or also a
  `tools/health/cli.py` matching the six approved-input precedents? ENG-0006-D
  names no Health interface and mentions the CLI only negatively.
- **Q-H7-6 — identifier authority.** May an operator author `envelope_id` in
  the input file, or must H7 **allocate** it and refuse an authored one?
  Allocation is the B2 mechanism and is what makes monotonicity meaningful;
  an authored identifier would let the operator choose placement in the series.
- **Q-H7-7 — content-level idempotency.** Should a byte-identical resubmission
  under a new identifier be refused as a duplicate? No committed requirement
  speaks to it; accepting it creates redundant records, refusing it requires a
  content index that does not exist.
- **Q-H7-8 — the `publication` refusal code.** D1 (R18) requires H7 to refuse a
  `publication` block. `parse()` refuses it as `UNKNOWN_FIELD`, not as a named
  prohibition. Is that sufficient, or should `publication` join the schema's
  `forbidden_fields` so the refusal is named? The latter is a schema amendment.

**Two smaller findings, recorded, not resolved:**

- **F-1 — `supersedes`/`superseded_by` are validated as free text**
  (`_text`), not as CHENV identifiers, and no referenced record's existence is
  checked. C2 will need this tightened; C1 should refuse the fields outright
  (§9).
- **F-2 — `hashlib` is not in the Health forbidden-import list.** A Health
  module could import it today without tripping any guard. That may be
  intentional (it reaches no host, socket or store), but it is undeclared.

---

## 15. GO / HOLD recommendation

**HOLD.**

Not because C1 is hard — §4 shows the validation is essentially already built
and §8 shows the persistence is already built — but because the **one thing C1
is actually for** is unresolved. C1 exists to make an envelope *authoritative*:
to establish that a human wrote this threshold. The validation and persistence
are the easy two-thirds; the authority is the point, and step 4 of §7 has no
committed mechanism behind it.

Proceeding now would mean choosing an approval model myself, which the brief
forbids and which would be the wrong way to acquire one.

**What a narrowed GO could look like, if the operator rules accordingly:**

Given rulings that (a) H7 covers **C1 only** (Q-H7-1), (b) a first envelope
needs **no** approving-identity field (Q-H7-2), (c) C1 **may** follow the
committed approved-input precedent, with its reliance on operator-controlled
filesystem permissions recorded as the accepted authority model and B-2/B-3
carried as documented residual risk (Q-H7-3, Q-H7-4), and (d) H7 **allocates**
the identifier (Q-H7-6) —

then C1 is implementable as roughly **120–160 lines** in one new module
`tools/health/ingest.py`, with **25 implementable test rows** (§12.1), two new
module-scoped import exceptions, one new allowlist entry, and no schema,
ADR, ontology or production change. Tests 26–30 would be explicitly deferred to
the increment that introduces an approval mechanism, and B-1 would remain an
open blocker against C2.

Without those rulings, I would be inventing the authority model that C1's
entire purpose depends on.

---

## 16. Regression baseline

Run against the committed H6A tree with **no implementation or test
modification** — this assignment adds one documentation file and nothing else.

| | executed | passing | failing |
|---|---|---|---|
| published baseline (H6A) | 159 | 131 | 28 |
| this run | **159** | **131** | **28** |

```
newly failing:      (none)
no longer failing:  (none)
identical membership (normalized): YES
AC 25: 20 assertions
production root: stat: cannot statx '/var/lib/kyri/health': No such file or directory
```

`HEAD^{tree}` was `870f20c1409d381c53875a329f44576e03790f63` before and after
the run, with the same single untracked file (this report) at both ends — so no
tracked file changed while it executed. Membership was compared by **normalized**
suite name.

The 28 failures are the pre-existing generation-installer and helper-ceremony
debt. **The suite as a whole is not GREEN and is not described as GREEN.**

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H7 readiness assessment for C1, human-authored envelope
ingestion. Planning only.

**Files Changed:** this report only —
`docs/development/reports/eng-0006/2026-10-24-eng-0006-h7-readiness-assessment.md`.
No implementation, test, schema, ADR, ontology, provisioning or other
documentation file was modified.

**Tests Executed:** the existing suites, unmodified, as a regression baseline —
see the handoff. No test was added or changed.

**Commands Run:** `git rev-parse`, `git log`, `git status`, `git fetch`,
`git ls-remote`; `cat`/`sed`/`grep` over the committed artifacts listed in §2;
`stat /var/lib/kyri/health`; the existing suites. No push, merge, rebase, tag
or deploy. No write to `/var/lib/kyri`, Fabric or Trust storage.

**Known Risks:** the three blockers in §13 and the eight questions in §14.

**Architecture Decisions:** none taken. Every proposal is marked **[D]** and
every blocker is referred for a ruling.

**Questions for Reviewer:** Q-H7-1 through Q-H7-8, plus findings F-1 and F-2 — §14.
