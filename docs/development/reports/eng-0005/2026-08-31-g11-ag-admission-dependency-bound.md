# ENG-0005 G11-AG — the structural admission dependency bound

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `1883bd3a46d9a5f2db74e33ed47a272460956962`
**Implementation commit:** `a0113d3beaedd50130b457e759cc552baa646351`

`admit_instance` checked three clock facts and never the fourth. It required the
advertisement to be fresh at `evaluated_at`, the binding not to begin before the
claim, and the admission window not to be already closed. It never required the
admission window to **end** inside the advertisement's.

So `admitted_until > advertisement.valid_until` was admissible, and the interval
`[valid_until, admitted_until)` is an R17 tail: the binding is
lifecycle-admitted with ELIG-7 open while ELIG-6 refuses. Historical
CINST-000001 has exactly that shape. G11-Q avoided it for CINST-000002 by
setting `admitted_until == CADV-000003.valid_until` **by hand** — ceremony
discipline, not structure.

The invariant is now enforced at the write:

```python
if admitted_until > expires:
    _refuse(REFUSED, REASON_ADMISSION_UNBOUNDED)
```

One comparison, against the `valid_until` the same clock block had already
parsed. No second parser, no policy constant, no configurable duration.

**Defence in depth, and nothing was traded for it.** G11-Y still re-evaluates
every condition at invoke and is untouched. What this removes is the ability to
*create* a tail, not the runtime refusal of one.

Three existing fixtures built their R17 tails *through* `admit_instance` and
could no longer do so. They now build them as legacy records — the shape a store
can still hold and CINST-000001 already has. Coverage is unchanged; only
construction moved.

One validation suite is red, for a reason that predates this work and is proved
below to be unrelated: `test-capability-invoke-preflight.sh` shapes a fixture
from the **live** production Fabric and evaluates it at the **wall clock**, and
the production chain expired yesterday at 16:19:19. §15 has the proof and §17
the recommendation.

Production was not mutated. CINST-000003 was not written.

---

## 1. Starting authority

Every value re-read from the repository and the host.

| Check | Observed |
| --- | --- |
| Branch | `arch/eng-0005-execution-transition` |
| HEAD / origin | `1883bd3a…`, identical, `0 0` divergence |
| Working tree | clean |
| G11-AF report | present, HEAD |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Fabric store | 21 files, `bcb2559b…f15e` |
| Trust store | present and readable |
| CIMP-000001 | `ecb38d80…9991b`, one file, no retirement |
| CINST count / seq | **2 / 2** |
| CADV count / seq | **3 / 3** |
| Route count / seq | **2 / 2**, head CROUTE-0002 |
| Selection count / seq | **1 / 1** |
| CINST-000003 | absent |
| CADV-000004 | absent |

## 2. The historical problem

`_window_open` and `_admitted` treat the admission window as
`admitted_at <= t < admitted_until`. `_advertised` treats the claim as
`observed_at <= t < valid_until`. Both are half-open and right-exclusive.

When the admission window extends past the claim, the two disagree on the
interval between them:

```
observed_at ──────────────── valid_until
admitted_at ─────────────────────────────── admitted_until
                             └──── R17 tail ────┘
                             ELIG-6 unmet, ELIG-7 met
```

Inside the tail the record still reads `lifecycle_state: admitted` and its
approving authority is intact, so ELIG-7 is satisfied; ELIG-6 refuses with
`advertisement-not-fresh`. The binding looks admitted and refuses only at
invoke — after the ceremony that produced it has been spent.

This is not hypothetical. G11-AA measured a non-zero R17 tail against
CINST-000001, and G11-AD carried
`ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES` on the grounds
that *"the next governed write is CINST-000003, which sets exactly this field"*.

## 3. RED reproduction

`tests/test-fabric-admission-dependency-bound.sh`, written before any source
change, against the released engine. Fixture: `T0` observed, `T2` valid_until,
`T1` admitted_at, `T3 = T2 + 1 day` admitted_until, everything else valid.

The released behaviour **accepted** it:

```
FAIL: an admission ending after its advertisement's validity is refused
FAIL: the refusal names the dependency: None == 'admission-window-exceeds-advertisement'
FAIL: the refused overlong admission allocated no instance identity
FAIL: one microsecond past valid_until is refused: the bound is not a tolerance
FAIL: preflight refuses the overlong admission with the same reason as the write
FAIL: a superseding admission is bounded by its own advertisement, not the old one
FAIL: the CINST-000001 shape would be refused if submitted today
...
10 assertion(s) failed.
```

`reason == None` with a returned `record_id` of `CINST-000001` — the write was
accepted outright.

And the tail it produces, evaluated at `T2 + 1h` through the released
predicates:

```
PASS: in the tail ELIG-6 refuses: the advertisement has lapsed
PASS: in the tail ELIG-7 is met: the admission window is still open
PASS: in the tail the binding is still lifecycle-admitted -- the R17 shape
```

Exactly 10 assertions failed and every other assertion in the suite passed,
which is the useful signal: the suite's expectations about *existing* behaviour
were already correct before the change, so the change had one job.

## 4. Half-open semantics

Stated precisely, because the choice between `<` and `<=` is the whole design.

| Window | Predicate | Where |
| --- | --- | --- |
| Advertisement | `observed_at <= t < valid_until` | `_advertised`, and `admit_instance` step 6 |
| Admission | `admitted_at <= t < admitted_until` | `_admitted`, `_window_open` |

Both exclude their right endpoint. So when `admitted_until == valid_until` the
two windows end at the same instant and that instant is outside **both**. There
is no interval in which admission is open and the claim is not. Equality is
exact coincidence, not a one-instant overhang.

The invariant is therefore `admitted_until <= valid_until`, and `<` would refuse
the very shape G11-Q deliberately produced for CINST-000002 and which the
reviewer prefers for CINST-000003.

No timezone conversion was introduced. The comparison is between two
already-parsed aware datetimes, both produced by `_stored_instant`, and naive
instants are still refused upstream by `_human_preflight` with
`timestamp-carries-no-offset`.

## 5. The invariant

> An admitted binding must not claim authority beyond the validity of the
> advertisement it depends on.

```
admitted_until <= advertisement.valid_until
```

## 6. Refusal vocabulary

`REASON_ADMISSION_UNBOUNDED = "admission-window-exceeds-advertisement"`.

All 80 existing reason constants were read before adding an 81st. None
describes this fact, and the three nearest were deliberately not overloaded:

| Existing reason | What it means | Why it is not this |
| --- | --- | --- |
| `advertisement-not-fresh` | the claim is outside its window **at `evaluated_at`** | here the claim is fresh; the defect is in the future |
| `admission-window-expired` | `evaluated_at >= admitted_until` | here the admission window is open |
| `invalid-validity-window` | the admission window is internally incoherent | here it is coherent; it is the *dependency* that is violated |

The new reason is the only one that says the claim is fine, the window is fine,
and the binding still reaches past the thing it rests on. Tests pin the exact
string, and assert it is declared exactly once and used through the constant.

## 7. Implementation

Two additions to `tools/fabric/admission.py`, 20 lines including comment.

The comparison sits in `accept()` step 6 — the existing clock block — after
`expires` has been parsed and after freshness, ordering and expiry have been
judged:

```python
if evaluated_at >= admitted_until:
    _refuse(REFUSED, REASON_ADMISSION_EXPIRED)
if admitted_until > expires:
    _refuse(REFUSED, REASON_ADMISSION_UNBOUNDED)
```

Three properties, each deliberate and each pinned by a test:

**It reuses the parsed value.** `expires` is the `_stored_instant` the freshness
rule used. Re-reading `advertisement.get("valid_until")` would create a second
path by which the bound and the freshness rule could come to disagree about the
same record.

**It is placed after the existing refusals, not before.** An advertisement that
is superseded, stale, or unresolvable is still reported as such. Those are the
actionable facts — the operator consumes the head, or renews — and reporting a
window complaint instead would send them to the wrong place. G11-H's ordering
comment already rules this for the superseded case and it is preserved.

**It is inside `accept()`, so preflight gets it for free.** See §9.

No new policy constant. The bound is a relation between two records the operator
already supplied, not a duration anyone configures.

## 8. Boundary cases

All nine from the brief, each pinned:

| # | Case | Outcome | Reason |
| --- | --- | --- | --- |
| 1 | `admitted_until < valid_until` | **ACCEPTED** | — |
| 2 | `admitted_until == valid_until` | **ACCEPTED** | — |
| 3 | `admitted_until > valid_until` | **REFUSED** | `admission-window-exceeds-advertisement` |
| 3b | `valid_until + 1µs` | **REFUSED** | same — the bound is not a tolerance |
| 4 | `admitted_at == valid_until` | REFUSED | `advertisement-not-fresh` — freshness still decides |
| 5 | malformed `admitted_until` | INVALID | `timestamp-carries-no-offset` |
| 5b | offset-free `admitted_until` | INVALID | `timestamp-carries-no-offset` |
| 6 | advertisement already stale | REFUSED | `advertisement-not-fresh` |
| 7 | superseded advertisement | REFUSED | `advertisement-record-superseded` (G11-H) |
| 8 | missing advertisement | NOT_FOUND | `unresolved-reference` |
| 9 | `admitted_until = None` | INVALID | `timestamp-carries-no-offset` |

Case 9 was **derived, not assumed**, as the brief required. `admitted_until` is
mandatory and `_human_preflight` examines it as an instant before the bound is
ever reached, so an absent dependency window is refused by the existing schema
rule. The test asserts the reason is *not* the new one, which is what makes it a
statement about ordering rather than a coincidence.

Cases 4 and 6 are worth noting: both are refused for freshness rather than for
the bound, even though both also violate it. That is the ordering in §7 working.

## 9. Preflight and write equivalence

Structural, not merely observed. `_governed` runs the same `accept()` closure in
both paths; under `_REHEARSING` it skips the critical section, replay lookup and
allocation, and returns `PREFLIGHT` instead of `ACCEPTED`. A check inside
`accept()` cannot apply to one and not the other.

Pinned anyway:

| Assertion | Result |
| --- | --- |
| preflight refuses the overlong admission with the same reason | PASS |
| the refused preflight left the instance sequence untouched | PASS |
| a dependency-bounded preflight would accept | PASS |
| the rehearsal mints no identity | PASS |
| `peek_next_id` still reports `CINST-000001` after the preflight | PASS |
| the real write accepts and lands on that identity | PASS |
| preflight and write compute the same request digest | PASS |

One correction to the brief's expectation: rehearsed instance admission returns
`record_id = None`, not a predicted identifier. That is released G11-H
behaviour — under `rehearsing()` nothing is minted, so there is nothing to
report — and the prediction is available from `peek_next_id`, which the write
then consumes. The test asserts the released behaviour rather than the expected
one.

## 10. Supersession regression

Unchanged, and pinned in the shape CINST-000003 will actually have: a renewed
advertisement superseding the first, and a superseding instance bounded by the
**new** claim.

| Assertion | Result |
| --- | --- |
| a superseding admission bounded by its new advertisement is accepted | PASS |
| the supersession created a new binding root, not an edit | PASS |
| the predecessor record was not mutated | PASS |
| a superseding admission overshooting its **own** new claim is refused | PASS |
| a superseded advertisement is still reported as superseded, not as unbounded | PASS |

The fourth is the one that matters for the next ceremony: the bound follows the
advertisement the instance *names*, so renewing the claim genuinely extends what
may be admitted, and does not let the old claim's window license the new
binding.

Replay protection, Trust re-evaluation at the new `evaluated_at`, the
advertisement-head requirement and route immobility are all untouched — no code
on those paths changed, and `test-fabric-instance-admission-integrity.sh` (G11-H)
passes unmodified.

## 11. Historical records

**Nothing was migrated, backfilled, rewritten or invalidated.**

CINST-000001 remains exactly as written. It would be refused if resubmitted
today — pinned — and that is the entire effect of this change on it. It already
fails closed at runtime through ELIG-6, and still does.

The bound is a **write-time** rule. It has no reader, no validator hook, and no
retrospective pass. `admit_instance` carries no migration path, asserted
directly against the source.

## 12. G11-Y coexistence

The write-time bound removes no runtime obligation, and the tests say so.

| Assertion | Result |
| --- | --- |
| ELIG-6 still refuses a bounded binding once its advertisement lapses | PASS |
| ELIG-7 still refuses it too — the windows now end together | PASS |
| inside the window ELIG-7 is still met — nothing over-tightened | PASS |
| ELIG-6, ELIG-7, ELIG-10, ELIG-11 are still evaluated at invoke | PASS |
| the bound was **not** copied into runtime eligibility | PASS |

That last one is deliberate. A bound admission can still become ineligible
through trust revocation, quarantine, host withdrawal, or the advertisement
being superseded — none of which the write can anticipate. `eligibility.py` was
not modified, and the new reason string appears nowhere in it.

`test-capability-invoke-current-eligibility.sh` passes in full, **including
Part 3, the R17 tail**:

```
PART 3 — the R17 tail: Fabric and invoke must agree
PASS: the fixture really has a tail: the instant is inside the admission window
      and past the advertisement
PASS: the Fabric refuses on ELIG-6 in the tail (unmet=['ELIG-6'])
PASS: the bridge refuses in the tail too (selected-instance-no-longer-eligible)
PASS: the refusal names current ineligibility
PASS: the underlying Fabric reason is carried for audit (('advertisement-not-fresh',))
```

### The fixtures that had to change, and why that is not a weakening

Three fixtures constructed their R17 tails by calling `admit_instance` with an
overlong window — which the bound now correctly refuses. They now construct the
same record without going through the write path:

| Suite | Change |
| --- | --- |
| `test-capability-invoke-current-eligibility.sh` | `world()` admits bounded, then extends the stored `admitted_until` with plain file IO |
| `test-fabric-runtime.sh` (ELIG-6 isolation) | admits bounded, then `variant_instance(...)` for the lapsed shape |
| `test-fabric-runtime.sh` (three-failure matrix) | same |

`variant_instance` is the suite's own pre-existing idiom for precisely this,
documented there as *"The released admission path refuses these states, which is
the point: a store can still hold one after damage or a legacy write."* The
tails these suites need are now exactly that category.

**What is asserted did not change** — every assertion in all three sections is
untouched. Only how the fixture reaches the record moved, from a write path that
now refuses to mint it to a direct construction of the artefact CINST-000001
already is. The suites test a runtime property, records of this shape still
exist, and the property must keep holding.

One further fixture change, of a different kind:
`test-fabric-runtime.sh`'s re-admission case requested
`admitted_until = YEAR + 30 days` against a claim valid to `YEAR + 1 day`, and
expected `trust-expired`. The bound fires first and would have masked the trust
check the case exists to prove. The request is now bounded at `YEAR + 1 day`,
so the refusal under test is the one that fires. That is the case getting
*stronger*, not weaker: it can now detect a trust regression it had begun to
hide.

## 13. The next renewal, in fixture

Derived, not written. The G11-AG suite exercises the exact shape:

| Record | Binding |
| --- | --- |
| CADV-000004 | fresh window, `supersedes: CADV-000003` |
| CINST-000003 | `supersedes: CINST-000002`, `advertisement_id: CADV-000004` |
| | `admitted_until <= CADV-000004.valid_until` |

Reviewer preference for the ceremony is `admitted_until == valid_until`, and the
half-open analysis in §4 shows why that is safe rather than merely tolerated.

**Equality is not hard-coded.** The source enforces `<=` only. A shorter
admission is a legitimate operator decision — deliberately declining authority
one has — and the platform has no business refusing it. Pinned by the
`admitted_until < valid_until` case accepting.

## 14. Generation impact

`tools/fabric/admission.py` is **not** in Generation 12's installed closure,
confirming G11-AC's finding directly against the live install:

```
/usr/lib/kyri/python/tools/fabric/  →  eligibility.py errors.py evidence.py
    identifiers.py __init__.py inspection.py models.py request_identity.py
    resources.py store.py trust_adapter.py validator.py
admission.py NOT INSTALLED
eligibility.py INSTALLED
```

`eligibility.py` *is* installed — and was not modified.

`test-fabric-runtime-install-closure.sh` passes, so the closure is still
coherent after the change. The installed runtime digest is unchanged at
`9cbfd043…33830` across 70 objects.

**`GEN13_INCLUDE_REQUIRED = NO`** for this change. The admission writer is an
operator-side governed operation, not part of the installed invoke runtime.
Generation 13 is still required for the preflight and the G6 backend; this
change does not add to it and was not forced into it.

## 15. Validation

### Suites

Every one of the 88 suite files the validator drives, run individually:

**87 pass, 1 fails.**

```
tests/test-capability-invoke-preflight.sh
```

### That failure is pre-existing and unrelated — proved

The suite shapes its fixture by copying the **live** production Fabric, and
evaluates it at the **wall clock**:

```python
at = instant or datetime.now(CT).isoformat()
```

The production chain expired at `2026-08-30T16:19:19-05:00`, deliberately and
under reviewer instruction. Every "would be accepted" assertion in it therefore
fails now, and would have failed regardless of this checkpoint.

Demonstrated by stashing the admission change and re-running:

```
=== baseline (my admission change stashed) ===
FAIL: a currently eligible binding would be accepted (False, admission-window-not-open)
FAIL: it reports the package tree digest without publishing it
FAIL: it reports current eligibility as its own field
FAIL: and the rehearsal names the scope refusal (admission-window-not-open)
FAIL: and reports the scope gate as failed
FAIL: and reaches the same conclusion the rehearsal reported (refused/...)
```

Identical failures, with the change absent. It is caused by the expired chain,
not by the bound.

**It does not affect CI.** The suite skips entirely when there is no production
Fabric to shape a fixture from — `SKIP: no production Fabric to shape a fixture
from` — which is the case in every workflow runner.

It was **not** fixed here. It is a distinct concern in G11-AA's territory, and
changing a suite that is failing for an unrelated reason, inside a checkpoint
about a different invariant, is the scope drift the project rules forbid. §17
carries it.

### Runner

| Run | Steps | Result |
| --- | --- | --- |
| `run-validation.sh --quick` | 79 | stopped at step 14, `Invoke preflight` |
| `run-validation.sh` (full) | 103 | stopped at step 38, `Invoke preflight` |

The runner aborts on first failure, so neither completed. The individual sweep
above is what establishes that everything else is green, including all 65 full-mode
steps after 38.

### Other gates

| Gate | Result |
| --- | --- |
| ShellCheck, repository-wide | clean |
| pre-commit (`bash -n`, shellcheck 0.9.0, whitespace, bytecode, static assertions) | all passed |
| Semgrep | runs containerised in CI; not installed locally. `.semgrep-exceptions.json` unchanged |
| GitHub CI, ShellCheck, Semgrep, CodeQL, Trivy, Gitleaks | see §19 |

The new suite is registered in both `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml` — `test-developer-experience.sh` enforces that a
locally-run suite is not omitted from CI, and caught the omission.

## 16. Production non-mutation

Identical before and after:

| Surface | Before | After |
| --- | --- | --- |
| Installed runtime | 70, `9cbfd043…33830` | 70, `9cbfd043…33830` |
| Fabric store | 21 files, `bcb2559b…f15e` | 21 files, `bcb2559b…f15e` |
| CIMP-000001 | `ecb38d80…9991b` | `ecb38d80…9991b` |
| CINST count / seq | 2 / 2 | **2 / 2** |
| CADV count / seq | 3 / 3 | **3 / 3** |
| Route count / seq | 2 / 2 | **2 / 2** |
| Selection count / seq | 1 / 1 | **1 / 1** |
| CINST-000003 | absent | **absent** |
| CADV-000004 | absent | **absent** |

No CADV, CINST, CROUTE, CSEL, CINV or CRES created. Nothing renewed. No stage,
no invoke. No CIMP, Trust or Evidence mutation. No runtime, helper or sudoers
install. Every suite that touches stores is fixture-only and asserts both
production stores are unchanged; the new suite does the same and reports
`PASS: the production Fabric and Trust stores are unchanged`.

## 17. Findings carried forward

1. **`test-capability-invoke-preflight.sh` is coupled to live production and to
   the wall clock** (§15). It needs its own checkpoint. The natural fix follows
   its existing idiom: skip, as it already does when production is absent, when
   the production chain cannot support the fixture — or pin the instant. Until
   then local full validation cannot complete while the chain stays expired.
2. `5cee2b53…` and `86762793…` still absent from repository authority (G11-AF).
3. `g5-supply-chain.sh:149-151` still hardcodes the superseded 3.14.7 candidate.
4. The G5 test fixtures still describe the non-admissible image.
5. `README.md:1381-1386` documents 12 approval fields; `APPROVAL_FIELDS` has 14.
6. `io.buildah.version` is recoverable from the artefact but ungoverned.
7. The effective container environment is six variables, not four.

Still separate, and deliberately not folded in:
`WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`,
`SEMGREP_RULESET_POLICY=DYNAMIC`.

## 18. Remaining dependency graph

`ADMISSION_BOUND_REQUIRED_BEFORE_NEW_CINST` is now **satisfied**. Seven items
remain, in the order G11-AF derived:

| # | Work | State |
| --- | --- | --- |
| ~~1~~ | ~~admission dependency bound~~ | **done, this checkpoint** |
| 2 | deployment-bound coordinator identity | next |
| 3 | G6 Podman backend | CIMP-000001 usable (G11-AF) |
| 4 | Generation 13 packaging | after 3 |
| 5 | Generation 13 install | after 4 |
| 6 | helper / sudoers ceremony | after 2 |
| 7 | CADV-000004 → CINST-000003 → CROUTE-0003 → CSEL-000002 | last |
| 8 | invoke preflight, then first production invoke | after 7 |

Fabric renewal stays last: every renewed record carries a finite window, and the
current chain expired precisely because it was written before the execution
system was ready.

## 19. Next checkpoint

**Deployment-bound coordinator authority**, then the G6 Podman backend with its
isolated test — which is where `interpreter_link`, `interpreter_sha256` and
`interpreter_target` close (G11-AF §10).

`COORDINATOR_AUTHORITY_REQUIRED_BEFORE_BACKEND_DEPLOY=YES` and
`GEN13_REQUIRED=YES` carry forward unchanged, as do
`NEW_IMAGE_REQUIRED=NO`, `NEW_CIMP_REQUIRED=NO`, `NEW_CPKG_REQUIRED=NO`,
`NEW_TRUST_REQUIRED=NO`, `CURRENT_PRODUCTION_CHAIN_EXPIRED=YES` and
`PRODUCTION_INVOKE_AUTHORISED=NO`.
