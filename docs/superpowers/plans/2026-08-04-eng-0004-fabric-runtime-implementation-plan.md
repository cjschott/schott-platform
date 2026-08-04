# ENG-0004 Fabric Runtime Implementation Plan

**Status:** Proposed — not accepted

> **For agentic workers:** Execute one increment at a time. Stop for independent
> review and explicit approval after each. **This plan authorises no
> implementation.** See §3.

**Goal:** Sequence the accepted
[ENG-0004 Fabric Runtime specification](../specs/2026-08-04-fabric-runtime-design.md)
into the smallest coherent set of independently reviewable, test-first
increments.

**Architecture:** Unchanged. Where this plan and the specification appear to
differ, **the specification governs.**

## 1. Controlling sources

1. [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
2. The [accepted ENG-0004 specification](../specs/2026-08-04-fabric-runtime-design.md) — **authoritative**
3. Released interfaces: `tools/common/immutable_store.py`, `tools/trust/query.py`,
   `tools/trust/store.py`, `tools/trust/cli.py`
4. `platform-model/schemas/capability-instance.schema.yaml` — the **fourteen**
   enumerated eligibility checks
5. Repository conventions: `tests/test-*.sh`, `tools/dev/run-validation.sh`,
   `.github/workflows/ci.yml`, `tests/test-developer-experience.sh`
6. Governance: [fabric governance boundaries](../../fabric/governance-boundaries.md),
   [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)

## 2. Global constraints

- **Test-first.** Red evidence retained before implementation.
- **Synthetic fixtures only.** Isolated temporary stores, destroyed after use.
  No production store, network, SSH, container, `ai/.env`, or in-repository
  store.
- Each increment is independently reviewable with its own commit boundary.
- **Stop before merge unless explicitly approved.**
- Gate 2 and production operation remain closed.

## 3. Gate model

**Gate 1 is an entry gate. Its three documented conditions are already
satisfied** — the Operator Root ceremony is complete, ENG-0001 released as
`v0.9.7`, ENG-0002 as `v0.9.8`. **Gate 1 has no separate acceptance ceremony.**

**Gate 1 satisfaction alone does not authorise implementation.** Implementation
remains unauthorised until this plan is independently reviewed and accepted
**and** the operator separately authorises creation of the implementation branch
and the first Red test.

This planning PR creates no implementation branch, writes no Red test or runtime
code, and selects no release version.

> **Resolved terminology correction (formerly PB-1).** An earlier revision of
> this plan recorded the difference between governance saying Gate 1 is
> *satisfied* and the ledger saying it was *not accepted* as an open blocker.
> **It is resolved, not open:** Gate 1 is an entry gate with no acceptance
> ceremony, and the ledger now reads "Gate 1 satisfied; implementation not yet
> authorised". No gate text changed.

**No planning blocker remains.**

## 4. Architecture invariants every increment must preserve

| # | Invariant |
|---|---|
| A1 | ENG-0004 owns admission, eligibility, lifecycle governance, routing, deterministic selection |
| A2 | ENG-0005 owns activation, execution, invocation; ENG-0006 owns health evaluation; ENG-0003 untouched |
| A3 | Fabric never grants or modifies Trust Plane standing |
| A4 | Human approval governs operator-authorised mutations |
| A5 | An admitted subject may advertise only itself, only within admitted scope |
| A6 | **C1 alone** physically writes the filesystem |
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
| A22 | Production operation stays closed behind Gate 2; no release version selected |

## 5. Component ownership

| Component | Proposed path | Logical record-creation authority | Physical writes |
|---|---|---|---|
| C1 Fabric Record Store | `tools/fabric/store.py` | none | **yes — exclusively** |
| C2 Record Validator | `tools/fabric/validator.py` | none | none |
| C3 Trust Verification Adapter | `tools/fabric/trust_adapter.py` | none | none |
| C4 Admission and Lifecycle | `tools/fabric/admission.py` | `CAPDEF` `CCON` `CPKG` `CHOST` `CADV` `CINST` **`CROUTE`** | none |
| C5 Eligibility Evaluator | `tools/fabric/eligibility.py` | none | none |
| C6 Selection Engine | `tools/fabric/selection.py` | **`CSEL` only** | none |
| C7 Evidence Assembler | `tools/fabric/evidence.py` | none | none |
| C8 Inspection and Validation | `tools/fabric/inspection.py` | none | none |

**§6.5 route creation and supersession belong to C4, not C6.** C6 reads
`CROUTE` records; it never creates or supersedes one.

### Other proposed new paths

| Path | Purpose |
|---|---|
| `tools/fabric/__init__.py` | package |
| `tools/fabric/models.py` | the eight accepted record models |
| `tools/fabric/identifiers.py` | per-kind identifier patterns and widths |
| `tools/fabric/request_identity.py` | `request_digest` canonicalisation |
| `tools/fabric/cli.py` | behavioural interface surface |
| `tests/test-fabric-runtime.sh` | behavioural suite |

### Existing files this plan expects to modify

| File | Increment | Why |
|---|---|---|
| `tests/test-static.sh` | 1 | **four** `tools/fabric` guard blocks (lines ~1392, ~1906, ~1929, ~1946) |
| `tests/test-capability-fabric.sh` | 1 | **two** `tools/fabric` guard blocks (lines ~196, ~774) |
| `.github/workflows/ci.yml` | 1 | run the new suite |
| `tools/dev/run-validation.sh` | 1 | wire the suite; `TOTAL_STEPS` 33 → **34**; quick-mode omission list |
| `tools/common/immutable_store.py` | 2 | per-kind identifier width (see §6) |
| `docs/fabric/capability-fabric.md`, `docs/fabric/node-model.md` | 12 | runtime now exists |
| `docs/history/v1.0-engineering-ledger.md` | 12 | ENG-0004 progress |

## 6. Two resolved implementation questions

### Mixed identifier widths

ADR-0012 assigns **four-digit** identifiers to `CAPDEF-0000`, `CCON-0000`,
`CPKG-0000`, `CHOST-0000`, `CROUTE-0000` and **six-digit** to `CADV-000000`,
`CINST-000000`, `CSEL-000000`.

The released `ImmutableStore.allocate_id()` **hardcodes six digits**
(`f"{prefix}-{candidate:06d}"`). Increment 2 therefore adds a **backward-
compatible per-kind width mechanism** — a class-level mapping defaulting to
**six** so every released store, including the Trust Plane, is unaffected.
Per-kind exhaustion refuses at that kind's maximum rather than rolling over.
This modifies a released shared module, so increment 2 requires
backward-compatibility tests and every released Trust Plane behaviour preserved.

### Runtime-suite wiring order

`tests/test-developer-experience.sh` iterates **every** `tests/test-*.sh` and
fails any suite not wired into `tools/dev/run-validation.sh`. Creating
`tests/test-fabric-runtime.sh` therefore breaks that assertion **immediately**.
Wiring cannot wait for a final increment: it lands in **increment 1**, together
with `TOTAL_STEPS` 33 → **34** (the script self-checks `STEP != TOTAL_STEPS` and
fails otherwise) and a quick-mode omission entry, since the fabric suite builds
synthetic stores and spawns the CLI exactly as `tests/test-trust-runtime.sh`
does. Quick mode stays **24**.

---

## Increment 1 — Fabric contract suite, models, guards, and wiring

**Objective.** A behavioural suite, the eight record models, the guard
narrowing, and full CI/validation wiring — as one Red→Green increment.

- **Created:** `tests/test-fabric-runtime.sh`, `tools/fabric/__init__.py`,
  `tools/fabric/models.py`, `tools/fabric/identifiers.py`
- **Modified:** `tests/test-static.sh`, `tests/test-capability-fabric.sh`,
  `.github/workflows/ci.yml`, `tools/dev/run-validation.sh`
- **Inspect first:** `tools/trust/models.py`, `tools/trust/identifiers.py`,
  the four guard blocks in `tests/test-static.sh` and two in
  `tests/test-capability-fabric.sh`, how `tests/test-trust-runtime.sh` is wired
  into `ci.yml` and `run-validation.sh`, `tests/test-developer-experience.sh:458`
- **AC:** 3, 32, 48, 55, 87 · **FC:** 3, 4
- **Red:** model/contract assertions — each of the eight types constructible,
  deterministic round-trip, unknown-field rejection, naive-timestamp rejection,
  **absent or unrecognised effect class refused**, four- vs six-digit identifier
  patterns enforced, and no ninth type present.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric'` — the package does not exist.
- **Green:** frozen dataclasses for the eight types; per-kind identifier
  patterns; remove **only** `tools/fabric` from the six guard blocks, preserving
  `tools/capability`, `tools/scheduler`, `tools/placement`, `tools/clustering`,
  `tools/routing`, `tools/health`, `tools/discovery`, `tools/lease`,
  `tools/enrollment`, `tools/admission`, `tools/capability_fabric`; update stale
  comments claiming no Fabric runtime may exist; wire the suite into `ci.yml`
  and `run-validation.sh`; `TOTAL_STEPS` 33 → 34; add the quick-mode omission
  line.
- **Focused:** `bash tests/test-fabric-runtime.sh`,
  `bash tests/test-static.sh`, `bash tests/test-capability-fabric.sh`,
  `bash tests/test-developer-experience.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** every package name except `tools/fabric` stays
  forbidden; unknown schema version refuses; no credential field on any model.
- **Docs:** none.
- **Excluded:** storage, admission, selection, evidence, execution.
- **Commit:** `feat: add fabric record models and wire the fabric suite`
- **Review checkpoint:** reviewer confirms exactly eight model types, exactly
  `tools/fabric` released from the guards, and a green full validation at 34/34.
- **Rollback:** revert; guards and step count return to their released state.

## Increment 2 — Fabric record store (C1)

**Objective.** The only physical writer, with per-kind identifier widths.

- **Created:** `tools/fabric/store.py`
- **Modified:** `tools/common/immutable_store.py` (per-kind width mechanism)
- **Inspect first:** `tools/common/immutable_store.py` — `allocate_id()`
  (`:06d`), `write_atomic`, `open_for_read`, `DIR_MODE` `0700`, `FILE_MODE`
  `0600`, `is_inside_git_repository`, `MAX_SEQUENCE`; `tools/trust/store.py`
- **AC:** 1, 2, 4, 39, 40, 41, 52, 68, 78 · **FC:** 1, 2, 6, 13, 19, 20, 21
- **Red:** assert four-digit allocation for `CAPDEF`/`CCON`/`CPKG`/`CHOST`/
  `CROUTE` and six-digit for `CADV`/`CINST`/`CSEL`; **released Trust Plane
  allocation still six-digit and byte-identical**; per-kind exhaustion refuses
  rather than rolling over; no-default-root refusal; repository-root refusal;
  overwrite refusal; **no update and no delete method exists**; new directories
  `0700` and records `0600`; an existing directory with wrong mode or ownership
  is **refused or reported, never silently changed**; full-resolution root
  containment on **both read and write**; directory **and** record symlink
  escape refused; path traversal refused; an allocation collision is a
  **storage conflict and never replay evidence**; concurrent allocation stays
  unique and monotonic.
- **Observable Red reason:** `AttributeError: module 'tools.fabric' has no
  attribute 'store'` on import, then four-digit allocation assertions failing
  against the hardcoded `:06d`.
- **Green:** `FabricStore(ImmutableStore)` declaring the eight `record_dirs`; a
  class-level per-kind width map defaulting to six. **No second physical write
  path.**
- **Focused:** `bash tests/test-fabric-runtime.sh`,
  `bash tests/test-trust-runtime.sh`, `bash tests/test-trust-plane.sh`,
  `bash tests/test-trust-migration.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** **A6**; released Trust Plane behaviour preserved
  exactly.
- **Docs:** none.
- **Excluded:** governed acceptance of any record — increments 2 and 3 write
  only test fixtures, never an accepted governed operation.
- **Commit:** `feat: add the immutable fabric store`
- **Review checkpoint:** reviewer confirms the shared-module change is
  backward-compatible and no second write path exists.
- **Rollback:** revert both files; increment 1 stands.

## Increment 3 — Record validator (C2)

**Objective.** Structural and referential validation that repairs nothing.

- **Created:** `tools/fabric/validator.py`
- **Inspect first:** `tools/trust/store.py` `validate()`;
  `ImmutableStore.validate()`
- **AC:** 31, 42 · **FC:** 3, 5, 16
- **Red:** assert malformed YAML and non-mapping content become **deterministic
  ordered findings rather than exceptions**; a **missing reference is reported
  for every referenced record class** — `CAPDEF`, `CCON`, `CPKG`, `CHOST`,
  `CADV`, `CINST`, `CROUTE`; identifier/filename mismatch reported; temp residue
  reported; **nothing is repaired**; findings are byte-identical across repeated
  runs; **stale or corrupt derived state is recomputed, never trusted**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.validator'`.
- **Green:** validation by reconstruction, returning ordered findings.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** parse, type, and datetime failures become findings
  rather than crashes.
- **Docs:** none.
- **Excluded:** repair; the inspection surface (C8, increment 10).
- **Commit:** `feat: add the fabric record validator`
- **Review checkpoint:** reviewer confirms C2 exists as its own component and is
  not absorbed into C8.
- **Rollback:** delete the module.

## Increment 4 — Request identity, digest, and evidence (C7)

**Objective.** Identity and evidence **before** any governed record can be
accepted.

- **Created:** `tools/fabric/request_identity.py`, `tools/fabric/evidence.py`
- **Modified:** `tools/fabric/models.py` (evidence fields on all eight types),
  `tools/fabric/store.py` (refuse a record whose evidence cannot be assembled)
- **Inspect first:** `tools/observation/evidence_builder.py` and
  `tools/integrity/snapshot_manager.py` — the **released** `sha256:` canonical-
  JSON convention; specification §6 identity contract and §11 evidence table
- **AC:** 5, 35, 62, 63, 75, 76, 77, 78, 81, 82, 83, 84 · **FC:** 7, 8, 9, 10
- **Red:** assert `request_id` is opaque, caller-supplied, and **never derived**;
  bounded-length and safe-comparison validation; identical content under
  **different `request_id`** yields independent records; **exact replay returns
  the original outcome and record identity and allocates nothing**; conflicting
  reuse fails closed as `request_identity_conflict` leaving the original
  untouched; unknown canonicalisation or digest version fails closed; the digest
  is deterministic; authoritative input changes it; **transport metadata,
  arrival time, log correlation identifiers, and record identity do not**; every
  accepted record carries actor, approving authority, causal references, trust
  evidence references where applicable, reason category, timezone-aware
  caller-supplied timestamp, `request_id`, `request_digest`, schema
  identity/version, and record identity; **a record missing any required
  evidence field is not written**; enumeration yields **no audit-record class**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.request_identity'`.
- **Green:** SHA-256 over canonical JSON, sorted keys, stable separators,
  `sha256:`-prefixed; evidence assembly and validation. **No new cryptographic
  algorithm. No ledger of any kind.**
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** **A8, A9, A14, A15**.
- **Docs:** none.
- **Excluded:** a request or replay ledger; a ninth record type.
- **Commit:** `feat: add fabric request identity and record evidence`
- **Review checkpoint:** reviewer confirms **no ledger and no ninth type**, and
  that no accepted record can be written without complete evidence.
- **Rollback:** revert; no governed acceptance path exists yet.

## Increment 5 — Trust verification adapter (C3)

**Objective.** Trust standing through released Trust Plane interfaces only.

- **Created:** `tools/fabric/trust_adapter.py`
- **Inspect first:** `tools/trust/query.py` — `get_current_trust`,
  `evaluate_subject`, `get_trust_record`
- **AC:** 7, 8, 46, 61, 71 · **FC:** 14, 15
- **Red:** assert absent, expired, revoked, malformed, and unverifiable trust
  each yield refuse/ineligible; an unavailable Trust Plane **fails closed with
  no cached or assumed verdict**; the adapter writes nothing; a history of
  successful selections alters no trust standing; **a repository-wide search
  proves no Fabric record asserts a subject is trusted or untrusted**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.trust_adapter'`.
- **Green:** a read-only adapter, no caching, no write path.
- **Focused:** `bash tests/test-fabric-runtime.sh`,
  `bash tests/test-trust-runtime.sh`, `bash tests/test-trust-plane.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** **A3** — zero Trust Plane writes.
- **Docs:** none.
- **Excluded:** creating any trust decision.
- **Commit:** `feat: add the fabric trust verification adapter`
- **Review checkpoint:** reviewer confirms zero Trust Plane writes.
- **Rollback:** delete the module.

## Increment 6 — Declaration, subject admission, advertisement (C4 part 1)

**Objective.** The first governed acceptances.

- **Created:** `tools/fabric/admission.py`
- **Modified:** `tools/fabric/evidence.py` (wire evidence into acceptance)
- **Inspect first:** `tools/trust/root_authority.py`; specification §6.1–6.3
- **AC:** 6, 9, 10, 11, 12, 49, 64, 66, 67, 85, 86 · **FC:** 5, 11
- **Red:** assert a governed mutation without an approving operator identity is
  refused; **trust alone creates no instance and eligibility names the absent
  admission as the unmet condition**; an unadmitted subject's advertisement is
  refused with **no queued and no authoritative state**; self-admission refused;
  an admitted subject publishes its own advertisement **without new human
  approval**; impersonation and scope widening refused; **a missing reference to
  any referenced record class refuses**; every rejected operation creates **no
  record**; **repeating a rejected operation after authoritative state changed
  is validated afresh**; exact replay and conflicting reuse behave per increment
  4 **on each of these operations**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.admission'`.
- **Green:** the §6.1–6.3 governed paths.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** **A4, A5, A12**; default ineligible; absence of a
  record is never permission.
- **Docs:** none.
- **Excluded:** instance admission, routes, eligibility, selection.
- **Commit:** `feat: add governed fabric declaration and subject admission`
- **Review checkpoint:** reviewer confirms rejected operations are zero-record
  and every accepted record carries complete evidence.
- **Rollback:** delete the module.

## Increment 7 — Instance admission, lifecycle, routes (C4 part 2)

**Objective.** Instance admission, every legal transition, and **route creation
and supersession**.

- **Modified:** `tools/fabric/admission.py`
- **Inspect first:** specification §6.4, §6.5, §6.6, §7 transition table, §10
  two-record request identity
- **AC:** 14, 15, 16, 17, 18, 19, 51, 69, 70, 72, 73, 79, 85 · **FC:** 17, 18
- **Red:** assert each legal transition writes its specified record; each
  illegal transition is **refused with a deterministic result, no record, and no
  authoritative state change**; expiry removes eligibility only; a fresh
  advertisement revives nothing; an empty scope intersection is a valid
  ineligible outcome; **an instance-admission rejection persists nothing, as
  well as a subject-admission rejection**; an expired admission **asserts
  nothing about trust**; a retired instance stays retired; host disappearance
  changes nothing authoritative; re-admission requires a new decision against
  **then-current** evidence; **supersession keeps both old and new records
  readable through the declared overlap window**; `CINST` commits **before**
  `CROUTE`, each under **its own `request_id`**, and reusing one identity for
  both is conflicting reuse.
- **Observable Red reason:** the transition and route assertions fail
  behaviourally — models, store, evidence, and admission all import cleanly, so
  the failures are missing lifecycle enforcement, not fixture errors.
- **Green:** the §7 transition table plus §6.5 route creation and supersession,
  **owned by C4**.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** **A3, A19** — no Fabric action labels trust.
- **Docs:** none.
- **Excluded:** eligibility computation, selection, execution.
- **Commit:** `feat: enforce fabric lifecycle transitions and route governance`
- **Review checkpoint:** reviewer confirms derived status is never persisted and
  that C4, not C6, owns `CROUTE`.
- **Rollback:** revert to increment 6.

## Increment 8 — Eligibility evaluator (C5)

**Objective.** Every eligibility check the schema enumerates, not merely "eight".

- **Created:** `tools/fabric/eligibility.py`
- **Inspect first:** `platform-model/schemas/capability-instance.schema.yaml`
  **ELIG-1 … ELIG-14**; ADR-0012 "How capabilities are trusted"
- **AC:** 13, 14, 42, 56, 57, 58, 59, 60 · **FC:** 16, 27, 28

**Schema-to-component enforcement map.** No enumerated check may disappear
because the prose says "eight".

| Schema check | ADR category | Enforced by |
|---|---|---|
| ELIG-1 package trust | 1 | **C5** |
| ELIG-2 host trust | 2 | **C5** |
| ELIG-3 contract compatible with requested version | 3 | **C5** |
| ELIG-4 package version compatible with contract | 3 | **C5** |
| ELIG-5 verified resource profile satisfies requirements | 4 | **C5** |
| ELIG-6 fresh, registered advertisement in validity window | 5 | **C5** |
| ELIG-7 admission exists, human-approved, unexpired | 6 | **C5** |
| ELIG-8 non-empty effective scope permitting the request | 7 | **C5** |
| ELIG-9 data classification within host ceiling | 8 | **C5** |
| ELIG-10 host not quarantined | — additional | **C5** |
| ELIG-11 package not quarantined | — additional | **C5** |
| ELIG-12 candidate not manually drained | — additional | **C5** |
| ELIG-13 candidate permitted by the route being resolved | — additional | **C6** (route membership, increment 9) |
| ELIG-14 contract effect class routable | — additional | **C6** (selection constraint, increment 9) |

ELIG-3 and ELIG-4 are the decomposition of ADR category 3. Quarantine (10, 11)
and drain (12) are deliberately separate — *"one is a trust judgement that
something is suspect; the other is an operator deliberately withdrawing a
working node"*.

- **Red:** assert **each of ELIG-1 … ELIG-12 failing in isolation** yields
  ineligible naming that check; version negotiation is exact intersection with
  empty → refuse; no upgrade, downgrade, nearest match, or best-effort; only
  declared compatibility consulted; unknown health never healthy; health cannot
  grant, override, broaden, or admit; **stale or corrupt derived state is
  recomputed for eligibility**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.eligibility'`.
- **Green:** a pure, deterministic, total function at a supplied instant.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** indeterminate → ineligible; **A17, A18**.
- **Docs:** none.
- **Excluded:** persisting eligibility; ELIG-13 and ELIG-14, which are C6's.
- **Commit:** `feat: add deterministic fabric eligibility`
- **Review checkpoint:** reviewer confirms all twelve C5 checks exist
  individually and eligibility is never stored.
- **Rollback:** delete the module.

## Increment 9 — Routing and deterministic selection (C6)

**Objective.** Route resolution, ordered selection, refusal records — `CSEL`
only.

- **Created:** `tools/fabric/selection.py`
- **Inspect first:** ADR-0012 "How routing occurs";
  `docs/fabric/failure-behaviour.md`; specification §8 selection constraints;
  ELIG-13 and ELIG-14
- **AC:** 20, 21, 22, 23, 24, 25, 26, 27, 38, 50, 53, 54, 65, 80 · **FC:** 22,
  23, 24, 26
- **Red:** assert identical inputs choose identically across repeated runs; the
  **first** candidate in human-declared order wins with no reordering by any
  measurement; **ELIG-13** — a candidate absent from the route is excluded;
  **no route at all refuses with an outcome distinguishable from
  no-eligible-candidate**; no eligible candidate refuses naming **every**
  candidate and its exclusion; `local-only` refuses rather than degrading;
  health removes only; **every one of the twelve §8 operations behaves correctly
  with no Health Runtime present**; **ELIG-14** — a `side-effecting` contract is
  unroutable and **no route may override**; selection returns a Fabric identity
  or `CSEL` and **never invokes**; package contents never loaded; a replayed
  `CSEL` refusal returns its original outcome; **an accepted `CSEL` outcome is
  reconstructable from records alone** — route, route version, every candidate,
  each exclusion, and the outcome; **stale derived state is recomputed for
  selection**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.selection'`.
- **Green:** the six-step routing algorithm writing `CSEL` for selections **and**
  refusals. C6 **reads** `CROUTE` and never creates or supersedes one.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** a static assertion over `tools/fabric/` forbidding
  **dynamic package loading, `importlib` or equivalent loading of capability
  artifacts, `exec`, `eval`, `subprocess`, `os.system` or equivalent execution,
  reading or importing package contents, and any invocation, activation, worker,
  provider connector, or execution adapter**. Ordinary Python imports remain
  permitted and necessary.
- **Docs:** none.
- **Excluded:** **any execution or invocation** — ENG-0005.
- **Commit:** `feat: add deterministic fabric selection`
- **Review checkpoint:** reviewer confirms C6 authorises only `CSEL` and no
  execution path exists.
- **Rollback:** delete the module.

## Increment 10 — Inspection and validation surface (C8)

**Objective.** Read-only inspection over C2, mutating nothing.

- **Created:** `tools/fabric/inspection.py`
- **Inspect first:** `tools/fabric/validator.py`; `tools/trust/cli.py`
  `command_validate_store`; `ImmutableStore.open_for_read()` — the **ENG-0002**
  contract
- **AC:** 28, 29, 30, 33, 44, 47 · **FC:** 1, 2, 3, 12, 25
- **Red:** assert inspection over a valid store leaves paths, modes, sizes,
  timestamps and digests identical; an **absent** store root is **not created**
  and **its parent directory is byte-unchanged**; an empty store reports empty
  **distinguishably from absent**; a malformed record surfaces C2's deterministic
  finding without crashing or repairing; temp residue is reported as debris and
  **not removed**; repeated validation is identical; **no implicit repair** under
  any condition.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.inspection'`.
- **Green:** `open_for_read()` plus C2, adding deterministic error handling the
  base validator lacks. C8 **exposes** C2's findings and does not replace C2.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** **A6** — not one byte written under any input.
- **Docs:** none.
- **Excluded:** repair, cleanup, backfill.
- **Commit:** `feat: add read-only fabric inspection`
- **Review checkpoint:** reviewer confirms digest and parent-directory equality
  before and after.
- **Rollback:** delete the module.

## Increment 11 — Interface integration

**Objective.** The twelve §8 operations wired end to end.

- **Created:** `tools/fabric/cli.py`
- **Inspect first:** `tools/trust/cli.py` — exit codes `0/1/2`, no default store
  root, approved-directory containment
- **AC:** 43, 45 · **FC:** 25
- **Red:** assert each operation's required output fields and error categories
  (`refused`, `invalid`, `not-found`, `conflict` including
  `request_identity_conflict`, `unavailable`); no default store root;
  deterministic output; **explicit recovery produces new records by a new
  decision only**; **a production-store digest and `ai/.env` comparison before
  and after the whole suite shows no change**.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.fabric.cli'`.
- **Green:** the minimum surface for the twelve operations.
- **Focused:** `bash tests/test-fabric-runtime.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** no identity, key, or secret accepted as an
  argument.
- **Docs:** none.
- **Excluded:** any execution verb.
- **Commit:** `feat: add the fabric runtime interface`
- **Review checkpoint:** reviewer confirms no execution verb exists.
- **Rollback:** delete the module.

## Increment 12 — Failure injection, concurrency, regression, documentation

**Objective.** Prove the failure matrix, request-identity races, and the bounded
partial state; then document.

- **Modified:** `tests/test-fabric-runtime.sh`, `tools/fabric/store.py`
  (request-identity serialisation seam), `docs/fabric/capability-fabric.md`,
  `docs/fabric/node-model.md`, `docs/history/v1.0-engineering-ledger.md`
- **Inspect first:** specification §9 failure matrix, §10 ordering and two-record
  request identity
- **AC:** 34, 74 · **FC:** all 28 exercised together

**Replay lookup without a ledger.** Replay resolution searches the
`request_id`/`request_digest` evidence fields across **exactly the eight
accepted record types**. There is **no persistent request index, replay ledger,
or ninth record type**. The request-identity check and the accepted write are
**serialised through C1**; any lock or sequence artifact used for that
serialisation is **owned physically by C1 and is not a Fabric record**.

- **Red:** assert interruption after the new `CINST` and before the new `CROUTE`
  leaves the new instance present, **no route naming it**, nothing selecting it,
  the cutover **uncommitted**, the old route still serving, the `CINST`
  operation **still exactly replayable under its own `request_id`**, and
  completion requiring an **explicit operator decision**; **concurrent exact
  reuse of one `request_id` produces one accepted record and returns its
  original identity**; **concurrent conflicting reuse produces one accepted
  record and one `request_identity_conflict`**; different request identities
  with identical content remain independent; a storage collision stays
  distinguishable from replay; concurrent record-identity allocation stays
  unique and monotonic; rejected non-selection requests stay zero-record and are
  validated afresh; an unavailable Trust Plane fails closed; permission and
  symlink violations refuse.
- **Observable Red reason:** the race assertions fail because no serialisation
  seam exists — concurrent same-`request_id` submissions produce two accepted
  records instead of one.
- **Green:** the request-identity serialisation seam in
  `tools/fabric/store.py`, using the released `fcntl.flock` discipline already
  used by `allocate_id()`. **No transaction is introduced** (**A21**). Then
  update the Fabric documents from "no runtime exists" to the implemented
  surface, and the ledger's ENG-0004 row.
- **Focused:** `bash tests/test-fabric-runtime.sh`,
  `bash tests/test-docs-static.sh`
- **Full regression:** `tools/dev/run-validation.sh`
- **Security / fail-closed:** no implicit cleanup, rollback, repair, backfill, or
  synthetic record; production digest and `ai/.env` unchanged.
- **Docs:** `docs/fabric/capability-fabric.md`, `docs/fabric/node-model.md`,
  `docs/history/v1.0-engineering-ledger.md`.
- **Excluded:** **a release version, a tag, and a GitHub Release** — the release
  ceremony is separate and separately authorised. Solving the non-transactional
  risk.
- **Commit:** `test: prove fabric failure, concurrency, and replay behaviour`
- **Review checkpoint:** final independent review; reviewer confirms the
  deferred risk is still deferred and no release version was selected.
- **Rollback:** revert; earlier increments stand.

---

## Coverage matrix — 87 acceptance criteria

Every number below has an observable assertion in the named increment's Red
section.

| Increment | Acceptance criteria |
|---|---|
| 1 | 3, 32, 48, 55, 87 |
| 2 | 1, 2, 4, 39, 40, 41, 52, 68, 78 |
| 3 | 31, 42 |
| 4 | 5, 35, 62, 63, 75, 76, 77, 78, 81, 82, 83, 84 |
| 5 | 7, 8, 46, 61, 71 |
| 6 | 6, 9, 10, 11, 12, 49, 64, 66, 67, 85, 86 |
| 7 | 14, 15, 16, 17, 18, 19, 51, 69, 70, 72, 73, 79, 85 |
| 8 | 13, 14, 42, 56, 57, 58, 59, 60 |
| 9 | 20, 21, 22, 23, 24, 25, 26, 27, 36, 37, 38, 50, 53, 54, 65, 80 |
| 10 | 28, 29, 30, 33, 44, 47 |
| 11 | 43, 45 |
| 12 | 34, 74 |

**Coverage: 87/87.** Deliberate repeats — **14** (increments 7 and 8: the empty
intersection is both a lifecycle outcome and an eligibility result), **42**
(3 and 8: derived staleness in the validator and in eligibility), **78** (2 and
4: collision-is-not-replay from the store side and the identity side), **85**
(6 and 7: subject-admission and instance-admission rejection).

## Coverage matrix — 28 failure conditions

| Increment | Failure conditions |
|---|---|
| 1 | 3, 4 |
| 2 | 1, 2, 6, 13, 19, 20, 21 |
| 3 | 3, 5, 16 |
| 4 | 7, 8, 9, 10 |
| 5 | 14, 15 |
| 6 | 5, 11 |
| 7 | 17, 18 |
| 8 | 16, 27, 28 |
| 9 | 22, 23, 24, 26 |
| 10 | 1, 2, 3, 12, 25 |
| 11 | 25 |
| 12 | all 28, exercised together |

**Coverage: 28/28.**

## Coverage — the eight accepted record types

| Record | Width | Introduced | Exercised |
|---|---|---|---|
| `CAPDEF-0000` | 4 | 1 | 2, 3, 4, 6 |
| `CCON-0000` | 4 | 1 | 2, 3, 4, 6, 8, 9 |
| `CPKG-0000` | 4 | 1 | 2, 3, 4, 6, 8 |
| `CHOST-0000` | 4 | 1 | 2, 3, 4, 6, 7 |
| `CADV-000000` | 6 | 1 | 2, 3, 4, 6, 7, 8 |
| `CINST-000000` | 6 | 1 | 2, 3, 4, 7, 8, 9, 12 |
| `CROUTE-0000` | 4 | 1 | 2, 3, 4, 7, 9, 12 |
| `CSEL-000000` | 6 | 1 | 2, 3, 4, 9 |

**No ninth persistent record type is introduced at any increment.**

## Risk review

| Risk | Preventing test or validation step |
|---|---|
| Accidental Trust Plane mutation | Increment 5 Red; `test-trust-runtime.sh`, `test-trust-plane.sh`, `test-trust-migration.sh` pass unchanged at every increment |
| Physical writes outside C1 | Increment 2 review checkpoint; repository-wide assertion that only `tools/fabric/store.py` performs filesystem writes |
| Replay misclassification | Increment 4 Red — new identity, exact replay, conflicting reuse asserted separately |
| Path collision treated as replay | Increments 2 and 4 Red — collision asserted a **storage conflict** |
| Partial multi-record state | Increment 12 Red — interruption between `CINST` and `CROUTE`, with the `CINST` still replayable |
| Symlink and path traversal | Increment 2 Red — directory **and** record escape refused, full resolution |
| Malformed or unsupported record version | Increments 1, 3, 10 Red — fails closed; malformed becomes a finding |
| Permission failures | Increment 2 Red — mode/ownership mismatch refused or reported, never silently changed |
| Concurrent identity allocation | Increments 2 and 12 Red |
| Concurrent same-`request_id` races | **Increment 12 Red** — exact and conflicting concurrent reuse |
| Missing or unavailable Trust Plane evidence | Increment 5 Red — fails closed, no cached verdict |
| Unknown health state | Increment 8 Red — unknown stays unknown |
| Deterministic-selection drift | Increment 9 Red — identical inputs choose identically |
| Side-effecting capability selection | Increment 9 Red — ELIG-14, no route override |
| Accidental ENG-0005 execution behaviour | Increment 9 static assertion — dynamic loading, `importlib`, `exec`, `eval`, `subprocess`, `os.system`, package-content reads, and any invocation/worker/connector forbidden |
| Persistent evidence escaping the eight-record boundary | Increment 4 Red and review checkpoint — enumeration yields exactly eight |
| Identifier-width regression in released stores | Increment 2 Red — Trust Plane allocation still six-digit and byte-identical |
| Unwired suite breaking developer-experience | Increment 1 — wiring lands with the suite |

## Planning blockers

**None.** The Gate 1 terminology question is resolved (§3). Every increment is
derivable from ADR-0012, the accepted specification, and the enumerated schema
checks without inventing architecture.

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
