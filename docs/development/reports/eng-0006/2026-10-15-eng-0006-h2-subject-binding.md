# ENG-0006-H2 — Subject identity and reference validation

**Date:** 2026-10-15 · **Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `0ce4ccc4ef98cc3cb8592a9eff445ad4278b0654`

**RESULT: REVIEW_REQUIRED.**

H2 enforces one rule: **a record's subject must equal the subject of every
record it cites.** Its input is a record plus the records it cites, both
supplied by the caller — the shape ENG-0006-D component A2 declares. There is no
store, no network, no resolution from persistence, and no identity authority.

*VERIFIED* marks a fact measured here; *RECOMMENDATION* marks my judgement;
*DEFERRED* marks something left to a later increment by the plan.

---

## 1. Starting state and commit ancestry

| Check | Result |
|---|---|
| Branch | `arch/eng-0006-health-runtime` |
| HEAD at entry | `0ce4ccc4ef98cc3cb8592a9eff445ad4278b0654` — matched |
| Remote at entry | aligned at the same commit |
| Worktree at entry | clean: 0 modified, 0 untracked |
| H1C three-file scope | intact: `records.py`, `test-health-records.sh`, H1C report |
| H1 suite registered | `run-validation.sh` ✓ · `ci.yml` ✓ |
| H1B guard suites present | 5 / 5 |
| Health store · `CH*` records · listener · daemon | **absent · 0 · 0 · 0** |
| Production Fabric | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| Production Capability Runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| Production Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |

Ancestry: `4a53aca` (published D) → `05cb92e` → `1eece19` (H1) → `870ad1f` (H1B)
→ `0ce4ccc` (H1C) → `02d26c6` (editorial) → H2.

---

## 2. Phase A — editorial commit

**`02d26c62ad6618ef2b6f49236c70a01ae8d86022`** — two files, **no executable
change**.

| Correction | What changed |
|---|---|
| **A1** H1C report | The final GREEN count read **431** in the §8 GREEN table and the §10 regression row; the suite reports **432**. Both corrected, and the delta against H1 corrected from +57 to **+58**. |
| **A2** `_instant()` docstring | Called its input "an RFC3339 instant". Replaced with the accepted contract: an **offset-aware timestamp string denoting a valid instant, with no canonical grammar imposed** — plus why none is imposed, and that the value is returned unchanged. |

**The interim result was preserved.** The `GREEN interim — 428 / 2` row is a
historical measurement and is untouched; only the two *final* figures moved.
*VERIFIED:* the report now contains **zero** occurrences of `431`, two of `432`,
and the `428 | 2` row intact.

**No executable behaviour changed — proven, not asserted.** The
**docstring-stripped AST of `records.py` is byte-identical** before and after,
compared by parsing both revisions, removing every docstring, and re-dumping.
Twenty-seven lines changed in the file; none of them is code. Accepted inputs,
refusal codes and serialisation are unchanged, confirmed by re-running the three
acceptance and three refusal cases and the H1 suite (exit 0, 432).

---

## 3. Exact H2 normative scope

*VERIFIED from the committed plan.* ENG-0006-D §5 maps **H2 → component A2**,
and A2 reads:

> **Purpose:** enforce the G13 binding — a record's subject must equal the
> subject of every record it cites.
> **In/out:** a record plus its cited records; a verdict with a mismatch class.
> **Spec:** `subject_binding: must-match-every-cited-record`,
> `identifier_format_sufficient: false`, `cross_subject_citation: refuse`,
> `nonexistent_reference: refuse` on CHSTATE/CHDEG/CHREC; the two ontology edges
> with `same_subject_required: true`.
> **Upstream:** A1. **Permissions:** none.
> **Failure:** refuse; name the mismatch class; echo no value.

**No discrepancy between the plan and this increment's brief.** The plan's
"a record plus its cited records" is contextual validation with **caller-supplied
records**, which is what the brief authorises and what is implemented.

### The three validation categories, as the brief requires

| Category | Definition | H2 |
|---|---|---|
| **Record-local** | decidable from one supplied record | already H1 — field presence, enums, identifier *syntax*, record-local conditionals |
| **Contextual** | requires independently supplied records | **THIS INCREMENT**, limited to records the **caller supplies** |
| **Operational** | requires runtime state, persistence, network or a live service | **not implemented, not reachable** — no store, no resolution, no lookup |

### The six normative rules, and where each is enforced

*Quoted from ADR-0013 "Referential integrity":*

| # | Rule | H2 |
|---|---|---|
| 1 | "Every health state's subject equals the subject of **every** observation it cites." | enforced |
| 2 | "Every transition record's subject equals the subject of the observations and states it cites." | enforced **for what CHDEG can cite** — see §14 |
| 3 | "Every recommendation's subject equals the subject of its cited state and, where present, its cited transition." | enforced |
| 4 | "A cited envelope's subject equals the state's subject." | enforced, for CHSTATE and CHDEG |
| 5 | "A reference to a record that does not exist is **refused**, not skipped." | enforced as *not supplied* — see below |
| 6 | "A refusal names the mismatch from a controlled vocabulary and echoes no value." | enforced; five new classes |

### Rule 5, stated honestly

H2 is given a record and the records it cites. **It can know that a citation was
not supplied. It cannot know that the cited record does not exist anywhere.** The
refusal class is therefore **`cited-record-not-supplied`**, not
"nonexistent-reference": naming it after what was actually observed keeps the
refusal truthful, and claiming non-existence would be an assertion this layer
has no basis for. The *behaviour* the schema demands — refuse, do not skip — is
exactly what happens.

### What H2 explicitly does not conclude

A syntactically valid identifier is **never** treated as proof that the named
entity exists, was authenticated, is trusted, is available, is eligible, or is
healthy. H2 compares subjects. *VERIFIED by assertion:* the module exposes no
`resolve`, `fetch`, `load`, `authenticate`, `verify_identity`, `exists`,
`lookup`, `store` or `trust` entry point, and its source contains no socket,
subprocess, HTTP, path-construction, store or cross-plane reference.

### One ontology inconsistency, reported not resolved

*VERIFIED:* `DERIVED_FROM_OBSERVATIONS` and `FOLLOWS_FROM_STATE` both carry
`same_subject_required: true`. **`EVALUATED_AGAINST` — state/event → envelope —
does not declare it.** The envelope binding is nonetheless required by three
other sources: `subject_binding: must-match-every-**cited**-record` on all three
schemas, ADR-0013 rule 4, and `governance-boundaries.md`. Three sources require
it and one is silent, so H2 enforces it. *RECOMMENDATION:* add the flag to
`EVALUATED_AGAINST` in a later ontology increment so the catalog agrees with the
schemas; this was **not** changed here, being outside H2's authorised files.

---

## 4. Requirement-to-test matrix

Every expected value is written in the test or read from the committed schemas.
**Nothing imports an accepted-value constant from `tools.health` and compares it
to itself.**

| Requirement | Normative source | Assertions |
|---|---|---|
| The four binding rules are declared on all three families | the three schemas | 12 |
| The citation map matches the schemas' declared fields | the six schemas | 12 |
| A consistent working set is accepted | rules 1–4 | 3 |
| Families that cite nothing bind vacuously | CITATIONS ∅ | 3 |
| Unused supplied records are permitted context | — | 1 |
| Cross-subject citation refused, every family and field | ADR-0013 r1–r4 | 9 |
| Subject **type** and **identifier** compared separately | brief §5 "separate assertions" | 1 |
| Unsupplied citation refused, not skipped | ADR-0013 r5 | 5 |
| An *absent* optional citation needs nothing supplied | schema optionality | 2 |
| Wrong-family supplied record refused | A2 "wrong-family references" | 2 |
| Substituted record refused | brief §5 "never silently substitute" | 1 |
| Malformed citation set refused | — | 6 |
| Unparsed record refused | H1 dependency | 4 |
| Identifier syntax proven insufficient | `identifier_format_sufficient: false` | 3 |
| No resolution, authentication or lookup surface | brief §5, §6 | 11 |
| Refusal names its class and leaks no value | ADR-0013 r6 | 2 |
| Caller-owned input is not mutated | brief §7 | 1 |
| **Total** | | **87** |

---

## 5. Implementation design

**Two entry points, added to `records.py`.**

**Why `records.py` and not a new module.** *VERIFIED constraint:* H1B established
a **closed allowlist** of exactly three files under `tools/health`, enforced by
four separate guard suites. A new module would fail all four, and §7 forbids
weakening a guard to obtain a pass. Putting H2 in `records.py` satisfies the
allowlist with **zero guard changes** — and subject binding is a property of
records, so the placement is honest rather than merely convenient.

```python
CITATIONS: Mapping[str, Mapping[str, tuple[str, bool]]]   # kind -> field -> (cited kind, is_sequence)
def citations_of(kind) -> Mapping[str, str]                # read-only
def validate_citations(record, cited) -> None              # raises, or returns None
```

**The citation map**, read against the schemas:

| Kind | Cites |
|---|---|
| `capability-health-state` | `derived_from_observation_ids` → CHOBS (sequence) · `envelope_id` → CHENV |
| `capability-degradation-event` | `derived_from_observation_ids` → CHOBS (sequence) · `hysteresis_first_observation_id` → CHOBS · `hysteresis_last_observation_id` → CHOBS · `envelope_id` → CHENV (optional) |
| `capability-health-recommendation` | `derived_from_state_id` → CHSTATE · `derived_from_event_id` → CHDEG (optional) |
| CHENV · CHBEAT · CHOBS | nothing — present with empty maps so a caller gets an answer, not a lookup failure |

**Fault order is fixed**, so identical inputs always produce an identical
refusal: **not supplied → wrong family → wrong identity → foreign subject.**

**Family is checked before identity, deliberately.** A wrong-family record can
never carry an identifier of the cited family — the prefixes differ — so the only
way to present one is under the cited key with its own, foreign, identity. Both
faults are then present, and an operator needs the more fundamental one named.
Checking identity first would have made `cited-record-kind-mismatch`
unreachable; the test asserts this order.

**Five refusal classes added to the closed vocabulary** in `errors.py`, required
by rule 6:

| Class | Fault |
|---|---|
| `cross-subject-citation` | the cited record's subject differs; the detail says `subject-type` or `subject-id` |
| `cited-record-not-supplied` | the record names a citation the caller did not supply |
| `cited-record-kind-mismatch` | the supplied record is of the wrong family for that field |
| `cited-record-identity-mismatch` | the supplied record's own identifier is not the key it was supplied under |
| `citation-set-malformed` | `cited` is not a mapping of identifier to parsed record |

Modifying `errors.py` is required by the contract — ADR-0013 demands a
controlled vocabulary — and this increment's brief places no restriction on it.
Every detail string is a constant; **no supplied value ever reaches a message**.

**What the function does not do:** it mutates nothing, resolves nothing,
remembers nothing, and permits unused supplied records because a caller passing
a whole working set is doing nothing wrong — refusing extra context would make
the function harder to use without making it safer.

---

## 6. Authorized files changed

| Status | File | Change |
|---|---|---|
| **M** | `tools/health/records.py` | `CITATIONS`, `citations_of()`, `validate_citations()` |
| **M** | `tools/health/errors.py` | five binding classes added to the closed vocabulary |
| **M** | `tools/health/__init__.py` | export the two entry points |
| **A** | `tests/test-health-binding.sh` | the H2 behavioural suite |
| **M** | `tools/dev/run-validation.sh` | registration + step counts 144→145, 169→170 |
| **M** | `.github/workflows/ci.yml` | one registration step |
| **A** | this report | — |

**No new module under `tools/health`** — the allowlist still names exactly three
files and all four guards pass. No schema, no ADR, no ontology, no guard suite,
no Fabric, Capability, Trust, collector or provisioning file.

---

## 7. RED-before-GREEN evidence

The suite was written first, from the normative clauses.

| Stage | Exit | PASS | FAIL |
|---|---|---|---|
| **RED-1** — no entry points | **1** | 12 | 2 (short-circuits on the missing functions) |
| **RED-2** — permissive stubs, codes absent | **1** | 32 | 8 (then halts: the suite names the codes) |
| **RED-3** — codes declared, validators still permissive | **1** | **39** | **17** |
| **GREEN** | **0** | **87** | **0** |

**RED-3 is the meaningful one.** Declaring the classes while leaving the
validators permissive separates *existence* from *behaviour*, so the 17 failures
are purely behavioural. The 12 passes in RED-1 are schema-oracle assertions that
hold regardless of implementation — the proof that the oracle is independent.

### Five sabotages, each caught by name

*VERIFIED.* Each is a one-line change leaving the module importable and the
consistent working set parsing:

| Sabotage | Exit | Failures | Caught |
|---|---|---|---|
| cross-subject comparison removed | 1 | 11 | **yes** |
| unsupplied citation skipped rather than refused | 1 | 5 | **yes** |
| substitution (identity) check removed | 1 | 1 | **yes** |
| `subject_type` ignored, only identifier compared | 1 | 1 | **yes** |
| wrong-family check removed | 1 | 2 | **yes** |

The module was restored byte-identically after each, verified by `cmp`.

### Two defects of my own, both in the tests

Both were malformed *fixtures*, not implementation faults, and both were caught
by H1 refusing to parse them. I had tried to build a wrong-family citation by
giving a record an identifier from the cited family — `obs("CHSTATE-000001", …)`
— which H1 correctly refuses, because `CHSTATE-…` is not a valid observation
identifier. That failure is what surfaced the design point in §5: a wrong-family
record **cannot** carry a matching identifier, so the family check has to come
first for its class to be reachable at all. The fixtures now key a validly
identified record under the cited slot, and the test asserts the order.

---

## 8. Positive and negative test results

*VERIFIED — 87 assertions, exit 0.*

| Group | Assertions | Result |
|---|---|---|
| Schema declarations present on all three families | 12 | pass |
| Citation map agrees with the schemas | 12 | pass |
| Consistent working sets accepted (state, transition, recommendation) | 3 | pass |
| Non-citing families bind vacuously | 3 | pass |
| Unused supplied context permitted | 1 | pass |
| **Cross-subject refused** — state→obs, state→env, transition→obs (one of several), transition→hysteresis first, transition→hysteresis last, transition→env, recommendation→state, recommendation→transition, same id under a different subject **type** | 9 | pass |
| **Unsupplied refused, not skipped** — missing obs, missing env, nothing supplied at all, one of several missing, optional cited-but-absent | 5 | pass |
| Absent optional citation needs nothing supplied | 2 | pass |
| **Wrong family refused** | 2 | pass |
| **Substitution refused** | 1 | pass |
| Malformed citation set refused (`None`, list, str, int, unparsed value, non-string key) | 6 | pass |
| Unparsed record refused (`None`, `{}`, str, raw payload) | 4 | pass |
| Identifier syntax proven insufficient | 3 | pass |
| No resolution/authentication/lookup surface; no banned import | 11 | pass |
| Refusal names its class and leaks no sentinel | 2 | pass |
| Caller-owned input unmutated | 1 | pass |

---

## 9. Identity and reference refusal guarantees

| Guarantee | How it holds |
|---|---|
| Subject **type** and **identifier** are separate assertions | compared as a pair; the refusal detail says which differs |
| Identifiers are preserved exactly | `validate_citations` reads and compares; it never writes, normalises or aliases |
| No new identity authority | no registry, no resolution, no store; the caller supplies every record |
| Syntactic validity ≠ authenticated identity | asserted: well-formed identifiers on a foreign-subject set are still refused |
| Wrong-family reference refused | `cited-record-kind-mismatch`, checked before identity |
| Substitution refused | `cited-record-identity-mismatch` — a supplied record's own id must equal its key |
| Nothing fabricated | an unsupplied citation refuses; it is never synthesised |
| Nothing silently substituted | see above |
| Ambiguity never resolved favourably | there is none to resolve — the set is keyed by the cited identifier — and faults refuse in a fixed order |
| Provenance not inferred from an identifier | H2 reads `subject_type`/`subject_id` only; it makes no provenance claim |
| No authentication claimed | no such code path exists |
| **Fail-inert** | every fault **refuses**; nothing returns a healthy, eligible or trusted verdict. `validate_citations` returns `None` or raises — it produces no Health state at all |
| Grants no eligibility, overrides no Trust, broadens no scope, triggers nothing, executes nothing, routes nothing | none of those capabilities exists in the module |

---

## 10. H1 regression results

*VERIFIED. Actual exit codes.*

| Suite | Exit | PASS | FAIL | Baseline |
|---|---|---|---|---|
| `test-health-binding.sh` **(new)** | **0** | **87** | 0 | — |
| `test-health-records.sh` | **0** | 432 | 0 | 432 — unchanged |
| `test-capability-health.sh` | **0** | 487 | 0 | 487 — unchanged |
| `test-capability-health-agreement.sh` | **0** | 88 | 0 | 88 — unchanged |
| `test-platform-model.sh` | **0** | 1003 | 0 | 1003 — unchanged |
| `test-docs-static.sh` | **0** | 993 | 0 | 993 — unchanged |
| `test-static.sh` | **0** | **873** | 0 | 872 — **+1, accounted below** |
| `test-capability-fabric.sh` | **0** | 538 | 0 | 538 — unchanged |
| `test-fabric-runtime.sh` | **0** | 8355 | 0 | 8355 — unchanged |
| `test-developer-experience.sh` | **0** | 141 | 0 | passes with the new registration |
| ShellCheck (new suite + driver) | **0** | — | — | clean |

**The `test-static.sh` +1 is accounted for, not assumed.** Diffing its passing
assertions before and after: **one added, zero removed** —
`PASS: shell script conforms to standards: tests/test-health-binding.sh`. It is a
per-file assertion over the shell scripts in the repository, so adding a suite
adds one.

---

## 11. AC 25 verification

*VERIFIED:* 21 mentions in `tests/test-fabric-runtime.sh`, **20 AC 25 assertions
passing**, suite exit 0. The Fabric remains independent of Health: the AST import
barrier, the behavioural proof with `tools.health` made unimportable, and the
negative fixtures all pass unchanged. **H2 added nothing the Fabric imports** —
`validate_citations` is called by no Fabric code, and no Fabric file changed.

---
## 12. Complete validation inventory

*VERIFIED by a complete per-suite inventory using **exit codes**. The full
driver halts at its first failure, so the sweep is the only way to obtain
complete membership.*

| | Suites | Passing | Failing |
|---|---|---|---|
| Established baseline | 153 | 125 | **28** |
| After H1 + H1B + H1C | 154 | 126 | **28** |
| **After H2** | **155** | **127** | **28** |

**The suite count changed, and is accounted for.** H2 registers one suite,
`tests/test-health-binding.sh`, which passes — so 154 → **155** suites and
126 → **127** passing. `run-validation.sh` moves 144 → **145** steps in quick
mode and 169 → **170** in full.

| Comparison against the established 28-suite baseline | Result |
|---|---|
| Newly failing | **0** |
| No longer failing | **0** |
| Membership | **identical** |

**The full platform validator remains red and is not claimed otherwise.** 28
failures stand, their root causes remain unestablished, the previous
environmental 18/10 split remains withdrawn, and the `__pycache__` hypothesis
remains unsupported. **No unrelated failure was repaired or suppressed.**

---

## 13. Production isolation verification

*VERIFIED, before and after.*

| Check | Result |
|---|---|
| `/var/lib/kyri/health` | **does not exist** |
| Production `CH*` records | **0** |
| Committed `CH*` records | **0** |
| Health service, daemon or listener | **none** — 0 Python listeners |
| Production Fabric digest | **unchanged** |
| Production Capability Runtime digest | **unchanged** |
| Production Trust digest | **unchanged** |
| Production configuration | **unchanged** |
| Production record rewritten | **none** |
| Root operations | **none** |
| `/opt/schott-platform` moved, replaced or redeployed | **no** |
| H1B allowlist | **still satisfied** — exactly three modules under `tools/health` |

The H2 suite is pure in-memory validation: no temporary directory, no fixture on
disk, nothing to clean up.

---

## 14. Deferred responsibilities and unresolved questions

### Deferred by the plan, untouched here

*DEFERRED.* No store or sequence allocator, no filesystem persistence, no
heartbeat receiver or authentication, no network listener, no collector, no state
derivation, no freshness calculation, no hysteresis evaluation, no
recommendations engine, no CSEL change, no eligibility subtraction, no Trust or
Capability change, no provisioning. **D1–D7 all remain deferred; D5 still blocks
heartbeat receiving.**

**H10 keeps its contextual responsibilities.** H2 did **not** take them: it
compares subjects on records the caller supplies and makes no judgement about
freshness, contradiction, envelope sufficiency or any derived state. The U1 gap
stands — a CHSTATE whose `review_required` should be set because of a null
freshness policy still parses, because deciding that needs the envelope and the
observations in an evaluating context, which is H10's job.

### Unresolved, recorded for the reviewer

| # | Question | Status |
|---|---|---|
| **Q-H2-1** | `EVALUATED_AGAINST` does not declare `same_subject_required`, while the three schemas and ADR-0013 require the envelope binding. H2 enforces it on the stronger authority. | *RECOMMENDATION:* add the flag to the ontology edge in a later increment. Not changed here — outside H2's authorised files. |
| **Q-H2-2** | ADR-0013 rule 2 says a transition's subject equals "the observations **and states** it cites". **CHDEG cites no state record**: `from_state`/`to_state` are state *values*, not identifiers. So that clause has no referent field, and H2 enforces it over the observations and the optional envelope — everything CHDEG can actually cite. | Reported rather than resolved. Either the rule's wording is loose, or CHDEG is missing a state citation; that is an architecture question. |
| **Q-H2-3** | H1 requires `envelope_id` to be a well-formed CHENV identifier on **every** CHSTATE, but the schema comment says it is "Null only when state is `unmonitored`". An `unmonitored` state with a null envelope is permitted by the schema and refused by H1. | Pre-existing H1 conformance gap, **outside H2's scope**. H2 handles a null or absent citation correctly regardless, so the behaviour is right either way. Worth its own small increment. |

**None of the three blocks H3.** Q-H2-1 and Q-H2-3 are small corrections in
other increments' files; Q-H2-2 is a wording question that changes nothing H2
does.

---

## 15. Recommendation for independent H2 acceptance

*RECOMMENDATION: accept H2.*

| Criterion | Result |
|---|---|
| Scope matches the committed plan | **yes** — component A2 verbatim, no reinterpretation |
| Only authorised categories implemented | **yes** — contextual with caller-supplied records; no operational surface exists |
| RED before GREEN | **yes** — 39/17 with codes declared and validators permissive, then 87/0 |
| Suite detects a wrong implementation | **yes** — five one-line sabotages, each caught by name |
| Oracle independent of the module | **yes** — schemas and hand-written fixtures; no accepted-value constant imported |
| No existing guard weakened | **yes** — all five H1B guards untouched and passing; the allowlist still names three modules |
| H1/H1C behaviour preserved | **yes** — 432 unchanged, all seven other suites unchanged bar one accounted +1 |
| AC 25 preserved | **yes** — 20 assertions passing |
| Baseline failures | **28, identical membership, zero introduced** |
| Production isolation | **complete** |
| Fail-inert | **yes** — every fault refuses; the function returns `None` or raises and produces no Health verdict at all |

**What H2 actually implements, in one sentence:** given a parsed Health record
and a caller-supplied map of the records it cites, it refuses unless every
citation was supplied, is of the declared family, carries the identity it was
supplied under, and shares the citing record's subject type **and** identifier —
naming which of the four failed, and echoing nothing.

## Related

- [ENG-0006-H1C parsing conformance](2026-10-14-eng-0006-h1c-parsing-conformance.md)
- [ENG-0006-H1B guard transition](2026-10-14-eng-0006-h1b-guard-transition.md)
- [ENG-0006-H1 record models](2026-10-13-eng-0006-h1-health-record-models.md)
- [ENG-0006-D implementation plan](2026-10-13-eng-0006-d-runtime-implementation-plan.md)
- [ADR-0013: The Capability Health Plane](../../../decisions/ADR-0013-capability-health-plane.md)
