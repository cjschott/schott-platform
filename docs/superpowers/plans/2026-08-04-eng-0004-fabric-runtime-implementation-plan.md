# ENG-0004 Fabric Runtime Implementation Plan

**Status:** Proposed — not accepted

> **For agentic workers:** Execute one increment at a time. Stop for independent
> review and explicit approval after each. **This plan authorises no
> implementation.** Merging it does not start ENG-0004; see §3.

**Goal:** Sequence the accepted
[ENG-0004 Fabric Runtime specification](../specs/2026-08-04-fabric-runtime-design.md)
into reviewable, test-first increments.

**Architecture:** Unchanged. This plan sequences the specification's
requirements; it does not reinterpret, extend, weaken, or replace them. Where
the specification and this plan appear to differ, **the specification governs.**

## 1. Controlling sources

1. [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
2. The [accepted ENG-0004 specification](../specs/2026-08-04-fabric-runtime-design.md) — **authoritative**
3. Released interfaces: `tools/common/immutable_store.py`, `tools/trust/query.py`,
   `tools/trust/store.py`
4. Repository testing and validation conventions: `tests/test-*.sh`,
   `tools/dev/run-validation.sh`, `.github/workflows/ci.yml`
5. Repository governance: [fabric governance boundaries](../../fabric/governance-boundaries.md),
   [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)
6. The specification's §14 implementation-planning outline

## 2. Global constraints

- **Test-first.** Red evidence retained before any implementation, per ENG-0001
  and ENG-0002 precedent.
- **Synthetic fixtures only.** Every behavioural test builds records in an
  isolated temporary store and destroys it. No production store, no network, no
  SSH, no container, no `ai/.env`, no store inside the repository.
- Each increment is independently reviewable with its own commit boundary.
- **Stop before merge unless explicitly approved.**
- No production operation. Gate 2 remains closed.

## 3. Gate model

**This planning PR does not accept Gate 1.** No implementation branch is
created, no Red test or runtime code is written, and no release version is
selected or changed. Gate 2 and production operation remain out of scope.

**Merging this plan does not by itself authorise implementation.** The accepted
specification states that ENG-0004 implementation begins only when the
specification is accepted **and** its own test-first plan, feature branch,
review, and release boundary exist. A separate operator decision is required
after independent review of this plan.

> **Planning blocker PB-1 — Gate 1 terminology requires operator direction.**
> Repository governance defines Gate 1 as an **entry gate whose three conditions
> are already satisfied**, not as an acceptance ceremony. The controlling text
> in [governance boundaries](../../fabric/governance-boundaries.md) reads:
>
> > ### Gate 1 — Fabric Runtime entry gate
> >
> > 1. **Operator Root Authority ceremony complete.** Satisfied: the external
> >    root exists as `TAUTH-000001`, established out of band by a human.
> > 2. **ENG-0001 released** — the root establishment lineage contract
> >    implemented test-first, independently reviewed and merged.
> > 3. **ENG-0002 released** — `validate-store` made genuinely read-only,
> >    independently reviewed and merged.
>
> and
>
> > **Permitted after Gate 1:**
> >
> > - **Runtime implementation** — the fabric engine may be built.
>
> All three conditions are met — the ceremony is complete, ENG-0001 released as
> `v0.9.7`, ENG-0002 as `v0.9.8`. On that text Gate 1 is **satisfied**, and it
> is the *accepted specification*, not Gate 1, that additionally requires an
> accepted plan before implementation begins.
>
> The merged ledger row states "Gate 1 not accepted", which uses *accepted*
> where governance uses *satisfied*. **Both readings forbid implementation
> today**, so nothing in this plan depends on resolving it. It is recorded here
> rather than silently settled: an operator should confirm whether "Gate 1
> accepted" is a distinct ceremony or a restatement of the specification's
> additional requirement. **No gate text is changed by this plan.**

## 4. Architecture invariants every increment must preserve

Each is drawn from the accepted specification. Any increment that would violate
one is wrong, and the increment stops rather than the invariant bending.

| # | Invariant |
|---|---|
| A1 | ENG-0004 owns admission, eligibility, lifecycle governance, routing, deterministic selection |
| A2 | ENG-0005 owns activation, execution, invocation |
| A3 | Fabric never grants or modifies Trust Plane standing |
| A4 | Human approval governs operator-authorised mutations |
| A5 | An admitted subject may advertise only itself, only within admitted scope |
| A6 | **C1 alone** has physical filesystem write authority |
| A7 | Record identity is independently allocated by the store |
| A8 | `request_id` is opaque and caller-supplied |
| A9 | `request_digest` is Fabric-derived via the accepted canonicalisation contract |
| A10 | Exact accepted replay returns the original outcome and identity |
| A11 | Conflicting request-identity reuse fails closed |
| A12 | Rejected non-selection operations are **zero-record** |
| A13 | Accepted selection refusals and no-candidate outcomes use `CSEL` |
| A14 | Persistent evidence exists only on the eight accepted record types |
| A15 | No request ledger, replay ledger, generic audit record, or ninth record type |
| A16 | `side-effecting` remains unroutable; no route may override |
| A17 | Version negotiation is exact, declared, fail-closed |
| A18 | Health is optional and removal-only |
| A19 | Multi-record ordering is `CINST` before `CROUTE` |
| A20 | Interrupted multi-record state stays observable and needs an operator decision |
| A21 | The inherited non-transactional write risk stays deferred |
| A22 | Production operation stays closed behind Gate 2 |

## 5. Proposed new paths

Labelled explicitly because they do not exist today.

| Proposed path | Purpose |
|---|---|
| `tools/fabric/__init__.py` | Fabric runtime package |
| `tools/fabric/models.py` | The eight accepted record models |
| `tools/fabric/identifiers.py` | Identifier patterns and prefixes |
| `tools/fabric/store.py` | `FabricStore` (C1) over the released `ImmutableStore` |
| `tools/fabric/request_identity.py` | `request_digest` canonicalisation (C7 support) |
| `tools/fabric/trust_adapter.py` | C3 — Trust Plane reads via released interfaces |
| `tools/fabric/admission.py` | C4 — admission and lifecycle |
| `tools/fabric/eligibility.py` | C5 — eight-condition evaluation |
| `tools/fabric/selection.py` | C6 — routing and deterministic selection |
| `tools/fabric/inspection.py` | C8 — read-only inspection and validation |
| `tools/fabric/cli.py` | Behavioural interface surface |
| `tests/test-fabric-runtime.sh` | Behavioural suite, mirroring `tests/test-trust-runtime.sh` |

Existing files expected to be **modified**: `tests/test-static.sh` (increment 1),
`.github/workflows/ci.yml` and `tools/dev/run-validation.sh` (increment 13),
`docs/fabric/*` documentation (increment 13).

---

## Increment 1 — Retire the architecture-only guards

**Objective.** Allow a Fabric runtime package to exist without turning the
static suite red for the wrong reason.

**Why first.** `tests/test-static.sh` currently asserts in **three separate
blocks** that `tools/fabric` must not exist — the v0.9.5 block (eleven package
names), the v0.9.3 block (`tools/fabric`, `tools/capability`,
`tools/enrollment`), and the v0.9.4 block (`tools/fabric`, `tools/capability`,
`tools/clustering`, `tools/scheduler`). `tests/test-capability-fabric.sh`
(510 assertions) additionally asserts architecture-only. Creating any runtime
file before these are deliberately narrowed produces a failure that looks like a
regression and is not one.

- **Files modified:** `tests/test-static.sh`, `tests/test-capability-fabric.sh`
- **Inspect first:** `tests/test-static.sh` guard blocks; `tests/test-capability-fabric.sh` header
- **Requirements covered:** enabling only. **AC:** 48. **FC:** none
- **Red:** none — this increment removes a guard rather than adding behaviour.
  It is the one increment with no Red step, and it must therefore change **no
  runtime behaviour at all**.
- **Green:** narrow each guard so ENG-0004's authorised package is permitted
  while **`tools/scheduler`, `tools/placement`, `tools/clustering`,
  `tools/discovery`, `tools/lease`, `tools/enrollment` remain forbidden**, and
  ENG-0005 execution paths remain forbidden.
- **Focused:** `bash tests/test-static.sh && bash tests/test-capability-fabric.sh`
- **Regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** the narrowing is **additive-prohibition
  preserving** — every name not required by ENG-0004 stays forbidden.
- **Docs:** none.
- **Excluded:** creating any runtime file.
- **Commit:** `test: permit the ENG-0004 fabric package and keep every other runtime forbidden`
- **Review checkpoint:** a reviewer confirms exactly which names were released
  from the guard and that ENG-0005/scheduler names were not.
- **Rollback:** revert the commit; no runtime file exists yet.

## Increment 2 — Record models and contract tests

**Objective.** The eight accepted record types as immutable models.

- **Files created:** `tools/fabric/__init__.py`, `tools/fabric/models.py`,
  `tools/fabric/identifiers.py`, `tests/test-fabric-runtime.sh`
- **Inspect first:** `tools/trust/models.py` (frozen-dataclass and
  validate-by-reconstruction precedent), `tools/trust/identifiers.py`
- **Requirements covered:** §7 record table, §10 versioning. **AC:** 3, 32, 55,
  87. **FC:** 3, 4
- **Red:** assert each of `CAPDEF-0000`, `CCON-0000`, `CPKG-0000`, `CHOST-0000`,
  `CADV-000000`, `CINST-000000`, `CROUTE-0000`, `CSEL-000000` is constructible,
  round-trips deterministically, rejects unknown fields, rejects naive
  timestamps, and that a contract without an effect class is refused.
- **Observable Red reason:** `ImportError: No module named 'tools.fabric.models'`
  — no model module exists.
- **Green:** frozen dataclasses with `to_dict()`, identifier patterns, effect
  class and determinism class on the contract model.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + `tools/dev/run-validation.sh`
- **Security / fail-closed:** unknown schema version refuses; **no ninth model**;
  no credential field on any model.
- **Docs:** none yet.
- **Excluded:** storage, admission, selection, any execution.
- **Commit:** `feat: add the eight accepted fabric record models`
- **Review checkpoint:** reviewer confirms exactly eight model types.
- **Rollback:** delete `tools/fabric/`; increment 1 guard narrowing stands.

## Increment 3 — Isolated storage primitives (C1)

**Objective.** `FabricStore` as the **only** physical writer.

- **Files created:** `tools/fabric/store.py`
- **Inspect first:** `tools/common/immutable_store.py` (`open_for_read`,
  `write_atomic`, `allocate_id`, `DIR_MODE`, `FILE_MODE`,
  `is_inside_git_repository`), `tools/trust/store.py` subclass precedent
- **Requirements covered:** §10. **AC:** 1, 2, 4, 39, 40, 41, 52, 68, 78. **FC:**
  1, 2, 6, 13, 19, 20, 21
- **Red:** assert no-default-root refusal, repository-root refusal, overwrite
  refusal, absent update/delete methods, mode `0700`/`0600`, symlink escape
  refusal, path-traversal refusal, allocation collision reported as a **storage
  conflict and never as replay**, and concurrent allocation uniqueness.
- **Observable Red reason:** `ImportError` on `tools.fabric.store`, then
  `AttributeError` for the absent `FabricStore` class.
- **Green:** subclass the released `ImmutableStore`, declaring `record_dirs` for
  the eight types. **Add no new write path.**
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** every other component must reach the filesystem
  only through this class (**A6**).
- **Docs:** none yet.
- **Excluded:** admission logic, eligibility, selection.
- **Commit:** `feat: add the immutable fabric store`
- **Review checkpoint:** reviewer confirms no second write path and no update or
  delete method.
- **Rollback:** delete `tools/fabric/store.py`.

## Increment 4 — Request identity and canonical digest

**Objective.** `request_id` handling and `request_digest` derivation.

- **Files created:** `tools/fabric/request_identity.py`
- **Inspect first:** `tools/observation/evidence_builder.py` and
  `tools/integrity/snapshot_manager.py` — the **released** `sha256:` canonical-
  JSON convention this must reuse
- **Requirements covered:** §6 identity contract. **AC:** 5, 75, 76, 77, 78, 81,
  82, 83, 84. **FC:** 7, 8, 9, 10
- **Red:** assert `request_id` is treated as opaque and **never derived**;
  identical content with different `request_id` yields independent records;
  exact replay returns the original identity and creates nothing; conflicting
  reuse fails closed as `request_identity_conflict`; unknown canonicalisation or
  digest version fails closed; digest is deterministic; authoritative input
  changes it; transport metadata, arrival time, log correlation identifiers, and
  record identity **do not**.
- **Observable Red reason:** `ImportError` on `tools.fabric.request_identity`.
- **Green:** deterministic SHA-256 over canonical JSON with sorted keys and
  stable separators, `sha256:`-prefixed. **No new cryptographic algorithm.**
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** bounded-length and safe-comparison validation on
  `request_id`; unknown version refuses.
- **Docs:** none yet.
- **Excluded:** persisting a request or replay ledger (**A15**).
- **Commit:** `feat: add fabric request identity and canonical digest`
- **Review checkpoint:** reviewer confirms **no ledger record type** was added.
- **Rollback:** delete the module.

## Increment 5 — Trust verification adapter (C3)

**Objective.** Resolve trust standing through released Trust Plane interfaces
only.

- **Files created:** `tools/fabric/trust_adapter.py`
- **Inspect first:** `tools/trust/query.py` (`get_current_trust`,
  `evaluate_subject`, `get_trust_record`)
- **Requirements covered:** §9. **AC:** 7, 8, 46, 61, 71. **FC:** 14, 15
- **Red:** assert absent, expired, revoked, malformed, and unverifiable trust
  each yield refuse/ineligible; an unavailable Trust Plane **fails closed with
  no cached or assumed verdict**; the adapter writes nothing; selection history
  never alters trust standing.
- **Observable Red reason:** `ImportError` on `tools.fabric.trust_adapter`.
- **Green:** a read-only adapter with no caching and no write path.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites; **`tests/test-trust-runtime.sh` and
  `tests/test-trust-plane.sh` must pass unchanged** (**A3**).
- **Security / fail-closed:** no trust write in either direction.
- **Docs:** none yet.
- **Excluded:** any trust decision creation.
- **Commit:** `feat: add the fabric trust verification adapter`
- **Review checkpoint:** reviewer confirms zero Trust Plane writes.
- **Rollback:** delete the module.

## Increment 6 — Registration and admission validation (C4, part 1)

**Objective.** Governed declaration, subject admission, and advertisement
registration.

- **Files created:** `tools/fabric/admission.py`
- **Inspect first:** `tools/trust/root_authority.py` (declaration-from-approved-
  input precedent); specification §6.1–6.3
- **Requirements covered:** §6.1–6.3. **AC:** 6, 9, 10, 11, 12, 49, 64, 66, 67,
  85, 86. **FC:** 5, 11
- **Red:** assert a governed mutation without an approving operator identity is
  refused; trust alone creates no instance; an unadmitted subject's
  advertisement is refused and **creates no queued state**; self-admission is
  refused; an admitted subject may publish its own advertisement **without new
  human approval**; impersonation and scope widening are refused; every rejected
  operation **creates no record**; repeating a rejected operation is **validated
  afresh**.
- **Observable Red reason:** `ImportError` on `tools.fabric.admission`.
- **Green:** the minimum governed paths for §6.1–6.3.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** default ineligible; absence of a record is never
  permission; **A4, A5, A12**.
- **Docs:** none yet.
- **Excluded:** instance admission, eligibility, selection.
- **Commit:** `feat: add governed fabric declaration and subject admission`
- **Review checkpoint:** reviewer confirms rejected operations are zero-record.
- **Rollback:** delete the module.

## Increment 7 — Instance admission and lifecycle enforcement (C4, part 2)

**Objective.** Instance admission and every legal transition; illegal
transitions refused.

- **Files modified:** `tools/fabric/admission.py`
- **Inspect first:** specification §6.4, §6.6, §7 transition table
- **Requirements covered:** §6.4, §6.6, §7. **AC:** 14, 15, 16, 17, 18, 19, 51,
  69, 70, 72, 79. **FC:** 17, 18
- **Red:** assert each legal transition writes its specified record; each
  illegal transition is **refused with a deterministic result, no record, and no
  authoritative state change**; expiry removes eligibility only; a fresh
  advertisement revives nothing; an empty scope intersection is a valid
  ineligible outcome; an expired admission **asserts nothing about trust**; a
  retired instance stays retired; host disappearance changes nothing
  authoritative; re-admission requires a new decision against **then-current**
  evidence.
- **Observable Red reason:** the transition assertions fail because no lifecycle
  enforcement exists; models and store already import cleanly, so failures are
  behavioural, not fixture errors.
- **Green:** the §7 transition table, enforced.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** **A3** — no Fabric action labels a subject trusted
  or untrusted.
- **Docs:** none yet.
- **Excluded:** selection, execution.
- **Commit:** `feat: enforce fabric lifecycle transitions`
- **Review checkpoint:** reviewer confirms derived status is never persisted as
  authoritative.
- **Rollback:** revert to increment 6.

## Increment 8 — Eligibility calculation (C5)

**Objective.** The eight-condition eligibility function.

- **Files created:** `tools/fabric/eligibility.py`
- **Inspect first:** ADR-0012 "How capabilities are trusted"; specification §5 C5
- **Requirements covered:** §5 C5. **AC:** 13, 14, 42, 56, 57, 58, 59, 60. **FC:**
  16, 27, 28
- **Red:** assert each of the eight conditions failing **in isolation** yields
  ineligible naming that condition; version negotiation is exact intersection
  with empty → refuse; no upgrade, downgrade, nearest match, or best-effort;
  only declared compatibility is consulted; unknown health is never healthy;
  health cannot grant, override, broaden, or admit; derived state is recomputed
  and authoritative for nothing.
- **Observable Red reason:** `ImportError` on `tools.fabric.eligibility`.
- **Green:** a pure, deterministic, total function at a supplied instant.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** indeterminate → ineligible; **A17, A18**.
- **Docs:** none yet.
- **Excluded:** persisting eligibility.
- **Commit:** `feat: add deterministic fabric eligibility`
- **Review checkpoint:** reviewer confirms eligibility is never stored.
- **Rollback:** delete the module.

## Increment 9 — Routing and deterministic selection (C6)

**Objective.** Route resolution, ordered selection, refusal records.

- **Files created:** `tools/fabric/selection.py`
- **Inspect first:** ADR-0012 "How routing occurs"; `docs/fabric/failure-behaviour.md`;
  specification §8 selection constraints
- **Requirements covered:** §6.5, §8. **AC:** 20, 21, 22, 23, 24, 25, 26, 27,
  50, 53, 54, 65, 80. **FC:** 22, 23, 24, 26
- **Red:** assert identical inputs choose identically every time; the **first**
  candidate in human-declared order wins with no reordering by any measurement;
  no eligible candidate refuses naming **every** candidate and its exclusion; a
  `local-only` request refuses rather than degrading to a remote instance;
  health removes only; every behaviour holds with **no Health Runtime present**;
  a `side-effecting` contract is unroutable and **no route may override**;
  selection returns a Fabric identity or `CSEL` and **never invokes**; package
  contents are never loaded; a replayed `CSEL` refusal returns its original
  outcome.
- **Observable Red reason:** `ImportError` on `tools.fabric.selection`.
- **Green:** the six-step routing algorithm, writing `CSEL` for selections **and**
  refusals.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** **A2, A13, A16** — no import, exec, or subprocess
  anywhere in `tools/fabric/`.
- **Docs:** none yet.
- **Excluded:** **any execution or invocation** — that is ENG-0005.
- **Commit:** `feat: add deterministic fabric selection`
- **Review checkpoint:** reviewer confirms no execution path exists.
- **Rollback:** delete the module.

## Increment 10 — Evidence fields on accepted records (C7)

**Objective.** Required evidence fields carried by accepted records only.

- **Files created:** `tools/fabric/evidence.py` *(proposed)*
- **Inspect first:** specification §11 evidence-ownership table
- **Requirements covered:** §11. **AC:** 35, 36, 37, 38, 62, 63, 87. **FC:** none
  new
- **Red:** assert every accepted governed record carries the §11 evidence
  fields; an accepted `CSEL` carries outcome, route, route version, every
  candidate and each exclusion; a rejected non-selection operation creates **no
  record**; **no audit-record class or audit namespace exists**; enumerating
  persistent records yields **only the eight accepted types**.
- **Observable Red reason:** the evidence-field assertions fail because records
  are written without them.
- **Green:** assemble and validate evidence fields; a record whose evidence
  cannot be assembled **is not written**.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** **A14, A15**; trust evidence referenced, never
  duplicated.
- **Docs:** none yet.
- **Excluded:** a ninth record type.
- **Commit:** `feat: carry fabric evidence on accepted records`
- **Review checkpoint:** reviewer enumerates persistent record types and
  confirms exactly eight.
- **Rollback:** revert; earlier increments stand.

## Increment 11 — Read-only inspection and validation (C8)

**Objective.** Inspection and validation that mutate nothing.

- **Files created:** `tools/fabric/inspection.py`
- **Inspect first:** `tools/trust/store.py` `validate()`; `tools/trust/cli.py`
  `command_validate_store` — the **ENG-0002 read-only contract** this must match
- **Requirements covered:** §8 ops 11–12, §10. **AC:** 28, 29, 30, 31, 33, 44,
  47. **FC:** 1, 2, 3, 12, 25
- **Red:** assert inspection over a valid store leaves paths, modes, sizes,
  timestamps and digests identical; an **absent** store root is **not created**;
  an empty store reports empty distinguishably from absent; a malformed record
  becomes a deterministic finding without crashing or being repaired; temp
  residue is reported as debris and **not removed**; repeated validation is
  identical; **no implicit repair** under any condition.
- **Observable Red reason:** `ImportError` on `tools.fabric.inspection`.
- **Green:** use `ImmutableStore.open_for_read()`; never initialise on a read
  path.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** **A6** — not one byte written under any input.
- **Docs:** none yet.
- **Excluded:** repair, cleanup, backfill.
- **Commit:** `feat: add read-only fabric inspection and validation`
- **Review checkpoint:** reviewer confirms digest equality before and after.
- **Rollback:** delete the module.

## Increment 12 — Interface integration

**Objective.** The §8 behavioural operations wired end to end.

- **Files created:** `tools/fabric/cli.py`
- **Inspect first:** `tools/trust/cli.py` — exit codes `0/1/2`, no default store
  root, approved-directory input containment
- **Requirements covered:** §8 operations 1–12. **AC:** 43, 45, 73. **FC:** 25
- **Red:** assert every operation's required output fields and error categories
  (`refused`, `invalid`, `not-found`, `conflict`, `unavailable`); no default
  store root; deterministic output; explicit recovery produces new records by a
  new decision only; **supersession writes `CINST` before `CROUTE`**.
- **Observable Red reason:** `ImportError` on `tools.fabric.cli`.
- **Green:** the minimum surface for the twelve operations.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** no identity, key, or secret accepted as an
  argument; **A19**.
- **Docs:** none yet.
- **Excluded:** any execution command.
- **Commit:** `feat: add the fabric runtime interface`
- **Review checkpoint:** reviewer confirms no execution verb exists.
- **Rollback:** delete the module.

## Increment 13 — Failure injection and concurrency

**Objective.** Prove the failure matrix and the bounded partial state.

- **Files modified:** `tests/test-fabric-runtime.sh`
- **Inspect first:** specification §9 failure matrix, §10 ordering table
- **Requirements covered:** §9, §10 ordering. **AC:** 34, 74. **FC:** all 28
  exercised together
- **Red:** assert interruption after the new `CINST` and before the new `CROUTE`
  leaves the new instance present, **no route naming it**, nothing selecting it,
  the cutover **uncommitted**, the old route still serving, and completion
  requiring an **explicit operator decision**; concurrent allocation stays
  unique and monotonic with the loser seeing a conflict; an unavailable Trust
  Plane fails closed; permission and symlink violations refuse.
- **Observable Red reason:** the injection assertions fail because no ordering
  or concurrency guarantee is exercised yet.
- **Green:** whatever minimum ordering discipline the assertions require —
  **no transaction is introduced** (**A21**).
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Regression:** all 17 suites + full validation
- **Security / fail-closed:** no implicit cleanup, rollback, repair, backfill, or
  synthetic record.
- **Docs:** none yet.
- **Excluded:** solving the non-transactional risk.
- **Commit:** `test: prove fabric failure and concurrency behaviour`
- **Review checkpoint:** reviewer confirms the deferred risk is still deferred.
- **Rollback:** revert; earlier increments stand.

## Increment 14 — Full regression, CI wiring, documentation

**Objective.** Wire the new suite into CI and validation; update Fabric docs.

- **Files modified:** `.github/workflows/ci.yml`, `tools/dev/run-validation.sh`,
  `docs/fabric/capability-fabric.md`, `docs/history/v1.0-engineering-ledger.md`
- **Inspect first:** how `tests/test-trust-runtime.sh` is wired in both files
- **Requirements covered:** repository conventions. **AC:** 45, 46, 48. **FC:**
  none
- **Red:** `tests/test-developer-experience.sh` asserts CI runs each suite; add
  the corresponding assertion for the fabric suite and watch it fail.
- **Observable Red reason:** the new assertion fails because `ci.yml` does not
  yet name `tests/test-fabric-runtime.sh`.
- **Green:** add the CI step and the validation step; update the ledger's
  ENG-0004 row to record implementation progress.
- **Focused:** `bash tests/test-developer-experience.sh`
- **Regression:** all 17 suites + `tools/dev/run-validation.sh` + containerised
  ShellCheck
- **Security / fail-closed:** production digest and `ai/.env` comparison before
  and after, per ENG-0001 and ENG-0002 precedent.
- **Docs:** Fabric documentation updated from "no runtime exists" to the
  implemented surface.
- **Excluded:** **a release version, a tag, and a GitHub Release** — the release
  ceremony is separate and separately authorised.
- **Commit:** `ci: run the fabric runtime suite`
- **Review checkpoint:** final independent review before any release decision.
- **Rollback:** revert; the runtime remains unwired.

---

## Coverage matrix — 87 acceptance criteria

| Increment | Acceptance criteria |
|---|---|
| 1 | 48 |
| 2 | 3, 32, 55, 87 |
| 3 | 1, 2, 4, 39, 40, 41, 52, 68, 78 |
| 4 | 5, 75, 76, 77, 81, 82, 83, 84 |
| 5 | 7, 8, 46, 61, 71 |
| 6 | 6, 9, 10, 11, 12, 49, 64, 66, 67, 85, 86 |
| 7 | 14, 15, 16, 17, 18, 19, 51, 69, 70, 72, 79 |
| 8 | 13, 42, 56, 57, 58, 59, 60 |
| 9 | 20, 21, 22, 23, 24, 25, 26, 27, 50, 53, 54, 65, 80 |
| 10 | 35, 36, 37, 38, 62, 63 |
| 11 | 28, 29, 30, 31, 33, 44, 47 |
| 12 | 43, 73 |
| 13 | 34, 74 |
| 14 | 45, 46, 48 |

**Coverage:** 1–87, every criterion mapped to at least one increment. Criteria
14, 46, 48, and 78 appear in more than one increment deliberately — each is
asserted once where it is introduced and again where a later increment could
regress it.

## Coverage matrix — 28 failure conditions

| Increment | Failure conditions |
|---|---|
| 2 | 3, 4 |
| 3 | 1, 2, 6, 13, 19, 20, 21 |
| 4 | 7, 8, 9, 10 |
| 5 | 14, 15 |
| 6 | 5, 11 |
| 7 | 17, 18 |
| 8 | 16, 27, 28 |
| 9 | 22, 23, 24, 26 |
| 11 | 1, 2, 3, 12, 25 |
| 13 | all 28, exercised together |

**Coverage:** 1–28, every condition mapped.

## Coverage — the eight accepted record types

| Record | Introduced | Exercised |
|---|---|---|
| `CAPDEF-0000` | 2 | 6, 10 |
| `CCON-0000` | 2 | 6, 8, 9, 10 |
| `CPKG-0000` | 2 | 6, 8, 10 |
| `CHOST-0000` | 2 | 6, 7, 10 |
| `CADV-000000` | 2 | 6, 7, 8, 10 |
| `CINST-000000` | 2 | 7, 8, 9, 10, 13 |
| `CROUTE-0000` | 2 | 9, 12, 13 |
| `CSEL-000000` | 2 | 9, 10 |

**No ninth persistent record type is introduced at any increment.**

## Risk review

| Risk | Preventing test or validation step |
|---|---|
| Accidental Trust Plane mutation | Increment 5 Red — adapter writes nothing; `test-trust-runtime.sh` and `test-trust-plane.sh` must pass unchanged at every increment |
| Physical writes outside C1 | Increment 3 review checkpoint; increments 8, 11 assert C5 and C8 hold no write path |
| Replay misclassification | Increment 4 Red — exact replay vs conflicting reuse vs new identity, asserted separately |
| Path collision treated as replay | Increment 3 and 4 Red — collision asserted as a **storage conflict**, never replay evidence |
| Partial multi-record state | Increment 13 Red — interruption between `CINST` and `CROUTE` asserted observable and uncommitted |
| Symlink and path traversal | Increment 3 Red — escape refused after full resolution |
| Malformed or unsupported record version | Increment 2 and 11 Red — fails closed; malformed becomes a finding, never a crash or repair |
| Permission failures | Increment 3 Red — mode/ownership mismatch reported, never silently corrected |
| Concurrent identity allocation | Increment 3 and 13 Red — uniqueness, monotonicity, loser sees conflict |
| Missing or unavailable Trust Plane evidence | Increment 5 Red — fails closed, no cached or assumed verdict |
| Unknown health state | Increment 8 Red — unknown stays unknown, never treated as healthy |
| Deterministic-selection drift | Increment 9 Red — identical inputs choose identically across repeated runs |
| Side-effecting capability selection | Increment 9 Red — unroutable, and **no route may override** |
| Accidental ENG-0005 execution behaviour | Increment 9 and 12 review checkpoints; static assertion that `tools/fabric/` contains no import, exec, or subprocess of package contents |
| Persistent evidence escaping the eight-record boundary | Increment 10 Red — enumeration yields exactly eight; increment 10 review checkpoint |

## Planning blockers

**PB-1 — Gate 1 terminology.** See §3. Requires operator direction; blocks no
increment, because both readings forbid implementation today.

No other planning blocker was identified. Every increment is derivable from
ADR-0012 and the accepted specification without inventing architecture.

## Explicitly out of scope

- Capability activation, invocation, execution — **ENG-0005**
- Health evaluation and health states — **ENG-0006**
- TrustGateway cutover — **ENG-0003**
- Scheduler, placement, clustering, leases — ENG-0007 / ENG-0008
- Production node admission, registration, routing, selection, execution — Gate 2
- Any release version, tag, or GitHub Release
- Solving the inherited non-transactional write risk

## Related records

- [ENG-0004 Fabric Runtime Design](../specs/2026-08-04-fabric-runtime-design.md)
- [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
- [Fabric governance boundaries](../../fabric/governance-boundaries.md)
- [Post-root runtime sequence](2026-08-03-post-root-runtime-sequence.md)
- [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)
