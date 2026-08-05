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
- **AC:** 32, 48, 55 · **FC:** 4
- **Dependency check:** models and identifiers only. **AC 3 moves to increment 6** (it needs an accepted declaration) and **AC 87 to increment 12** (it needs a fully exercised store).
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
- **AC:** 1, 2, 4, 34 (allocation and commit race), 39, 40, 41, 52, 68, 78 · **FC:** 1, 2, 6, 13, 19, 20, 21
- **Red — AC 68, repository-wide.** Assert that **no file under `tools/fabric/`
  except `store.py`** reaches the filesystem by any mechanism: builtin
  `open(...)` in any writing mode; `os.open`, `os.write`, `os.mkdir`,
  `os.makedirs`, `os.chmod`, `os.chown`, `os.rename`, `os.replace`, `os.link`,
  `os.symlink`, `os.remove`, `os.unlink`, `os.rmdir`, `os.truncate`,
  `os.ftruncate`, `os.fdopen`; `pathlib` `.write_text`, `.write_bytes`,
  `.mkdir`, `.touch`, `.chmod`, `.rename`, `.replace`, `.unlink`, `.rmdir`,
  `.symlink_to`, `.hardlink_to`; `shutil` `.copy*`, `.move`, `.rmtree`;
  `tempfile` `.NamedTemporaryFile`, `.mkstemp`, `.mkdtemp`, `.TemporaryFile`;
  and `ImmutableStore.write_atomic`/`write_record`. The assertion must also
  catch **alias imports** — `from os import replace as _r`, `import os.path as
  _p`, `import shutil as sh` — by checking imported-name bindings, not only
  dotted call text. **C1's cleanup of its own `.tmp` file remains allowed** and
  is the single named exemption. A review checkpoint cannot provide this.
- **Red:** also assert four-digit allocation for `CAPDEF`/`CCON`/`CPKG`/`CHOST`/
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
  against the hardcoded `:06d` at `tools/common/immutable_store.py:153`.
- **Green — named seams.** Each assertion above becomes Green through a specific
  seam, not through inheritance:

  | Requirement | Seam |
  |---|---|
  | Per-kind widths | **New class attribute `ImmutableStore.id_widths: Mapping[str, int] = {}`**. Line 153 becomes `f"{prefix}-{candidate:0{self.id_widths.get(kind, 6)}d}"`. An empty map means six, so **every released store, including `TrustStore`, is byte-identical** |
  | Per-kind maximum | Exhaustion checked against `min(10**width - 1, MAX_SEQUENCE)` for that kind, refusing rather than rolling over |
  | **Sequence path containment** | `allocate_id()` (`:132`) opens `sequences/<kind>.seq` **directly**. `FabricStore` overrides it to run `_guard_path()` on the `sequences/` directory **and** the `.seq` file before `os.open`, then delegates to `super().allocate_id()` |
  | **Destination + temp-sibling containment** | `write_atomic()` (`:171`) accepts an arbitrary destination and creates a `.<stem>.tmp` sibling. `FabricStore` overrides it to `_guard_path()` **both the destination and the computed temporary sibling**, then calls `super().write_atomic()` — **the physical write body is delegated, never copied** |
  | **No containment bypass** | Because the override validates and delegates, a caller invoking `write_atomic()` directly is still guarded. A static assertion additionally proves no `tools/fabric/` module calls `ImmutableStore.write_atomic` unbound or via `super()` outside `store.py` |
  | **Validation path containment** | `validate()` (`:238`) globs record directories directly; the override guards each record directory before delegating |
  | **Counting path containment** | `counts()` (`:258`) globs directly; the override guards each record directory before delegating |
  | **No silent permission correction** | `FabricStore` overrides `_create_directories()`. The inherited body (`:90–99`) calls `mkdir(exist_ok=True)` then `chmod(DIR_MODE)` **on directories that already exist** — that is the silent correction. The override stats each existing path **first** and **refuses or reports without `chmod` or `chown`**. Only paths this call newly created are chmodded |
  | **Permission checks, every path class** | Mode is verified on the **store root, each record directory, `sequences/`, each sequence file, and each record file** — `0700` for directories, `0600` for files, and never world- or group-readable |
  | Restrictive creation modes | New directories `DIR_MODE` `0700`; new files `FILE_MODE` `0600`, from the released constants |
  | **Symlink refusal before following** | `_guard_path()` checks `Path.is_symlink()` on the **unresolved** path and each unresolved parent **first**, refusing before any resolution follows it; only then does it `resolve()` and require the result to be **inside or equal to** the resolved root |
  | Traversal | Refused by the same `_guard_path()` after full resolution |
  | One physical write path | `super().write_atomic()` is the only physical writer; nothing is copied |
  | No update/delete | Neither method is added; a static assertion proves `tools/fabric/` defines no `update`, `delete`, `unlink`, or `rmtree`, **except C1's own cleanup of its own `.tmp` file** |

  A **no-op, overridable synchronisation hook** is also introduced here so the
  increment-12 race Red has a seam that already exists. It has no production
  behaviour and writes nothing.

  `id_widths` is a **backward-compatible opt-in hook**: increment 2 must include
  regression assertions that `TrustStore` allocation, modes, and every released
  Trust Plane behaviour are unchanged.

  **Identifier widths, containment, modes, and symlink refusal require no new
  architectural decision** — they come from ADR-0012 and specification §12.
  **Ownership does — see planning blocker PB-2 (§14).** Until it is decided,
  this increment **captures and reports** each path's `st_uid`/`st_gid` as an
  observable finding and **refuses to change ownership**, but asserts no
  expected value.
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
- **AC:** 31, 32 (repeat: unsupported version on a stored record) · **FC:** 3, 5 (validator-visible missing reference), 16 (**reporting only**)
- **Dependency check:** C2 may **report** a stale, missing, malformed, or corrupt derived artifact. It **must not claim to recompute eligibility or selection** — C5 and C6 do not exist yet. **AC 42 moves to increments 8 and 9**: eligibility recomputation to 8, selection recomputation to 9.
- **Red:** assert malformed YAML and non-mapping content become **deterministic
  ordered findings rather than exceptions**; a **missing reference is reported
  for every referenced record class** — `CAPDEF`, `CCON`, `CPKG`, `CHOST`,
  `CADV`, `CINST`, `CROUTE`; identifier/filename mismatch reported; temp residue
  reported; **nothing is repaired**; findings are byte-identical across repeated
  runs; **a stale, missing, or corrupt derived artifact is reported as a
  finding** — C2 reports it and recomputes nothing.
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
- **AC (primitives):** 35, 62, 63, 76, 77, 81, 82, 83, 84 · **FC:** 7, 8, 9, 10
- **Dependency check:** identity, digest, evidence construction and replay lookup are **primitives**. **AC 5 and 75 move to increment 6** and **AC 78 stays in increment 2**; AC 35, 63, 76 and 77 are re-asserted **end to end** at every accepted-operation increment (6, 7, 9).
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
- **AC (adapter results only):** 46, 61, 71 · **FC:** none owned outright
- **Dependency check:** C3 returns **deterministic read-only trust-verification results**. It **does not itself claim admission refusal or eligibility outcomes** — those integrations belong to C4 (increments 6 and 7) and C5 (increment 8). **AC 7 and 8, and FC 14 and 15, are therefore mapped to 6, 7 and 8**, where a refusal or an ineligible verdict is actually observable.
- **Red:** assert the adapter returns a **deterministic `unverified` result**
  for absent, expired, revoked, malformed, and unverifiable trust, and for an
  unavailable Trust Plane, **with no cached or assumed verdict and no retry**;
  identical inputs return identical results; the adapter **writes nothing**; a
  history of successful selections alters no trust standing; **a repository-wide
  search proves no Fabric record asserts a subject is trusted or untrusted**.
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
- **AC:** 3, 5, 6, 7 (integrated), 8 (integrated), 11, 12, 35 (repeat), 37, 49 (part-1 classes), 55 (repeat, declaration boundary), 63 (repeat), 64, 66, 67, 75, 76 (repeat), 77 (repeat), 79 (part-1), 85 (subject admission), 86 · **FC:** 5, 7, 11, 14 (integrated), 15 (integrated)
- **Dependency check:** **C5 does not exist yet.** The "eligibility names the absent admission" halves of **AC 9 and 10 move to increment 8**; increment 6 asserts only that trust alone creates no instance record.
- **Red:** assert a governed mutation without an approving operator identity is
  refused; **trust alone creates no instance record** — the eligibility half of
  this scenario is asserted in increment 8, where C5 exists;
  **end-to-end declaration identity (AC 3, 5, 75, FC 7):** submit byte-identical
  declaration content under **two different `request_id` values**, then assert
  **two independently allocated records**, that **neither submission is treated
  as replay**, and that **neither overwrites the other**;
  **declaration-boundary effect class (AC 55):** a contract whose effect class is
  **absent or unrecognised** makes the declaration **refuse with zero records** —
  model validation in increment 1 does not prove this;
  **C3 integration at subject admission (AC 7, 8, FC 14, 15):** invalid, expired,
  revoked, malformed, and unverifiable host trust each **refuse admission with no
  record**, and Trust Plane unavailability **refuses with no cached verdict and
  no record**; an unadmitted subject's advertisement is
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
- **AC:** 7 (integrated), 8 (integrated), 9 (authoritative half), 15, 16, 17 (authoritative half), 18 (authoritative half), 19, 35 (repeat), 37 (repeat), 49 (part-2 classes), 51 (authoritative half), 63 (repeat), 64 (repeat), 69 (authoritative half), 70, 72, 73, 76 (repeat), 77 (repeat), 79 (instance admission), 85 (instance admission) · **FC:** 5 (part-2 classes), 11 (repeat), 14 (integrated), 15 (integrated), 17 (authoritative half), 18 (authoritative half)
- **Dependency check:** **C4 behaviour only — no eligibility, no selection.** The eligibility halves of **AC 14, 17, 18, 51 and 69 move to increment 8**; the selection half of **AC 51 moves to increment 9**; **FC 17 and 18 move to increment 8**.
- **Red:** assert each legal transition writes its specified record; each
  illegal transition is **refused with a deterministic result, no record, and no
  authoritative state change**; **an expiry lapse writes no record and changes
  no authoritative state** — its eligibility consequence is asserted in
  increment 8; a fresh advertisement **writes no revival record**; **an
  instance-admission rejection persists nothing, as well as a subject-admission
  rejection**, and repeating either after authoritative state changed is
  **validated afresh**; an expired admission **writes nothing to any trust
  record**; a retired instance **stays retired and is not reactivated by a
  returning host**; **host disappearance changes no authoritative record**; a
  re-admission is a new decision evaluated against **then-current** evidence;
  **supersession keeps both old and new records readable through the declared
  overlap window**; route creation and supersession write `CROUTE`; every
  accepted part-2 record carries its complete §11 evidence, and exact replay and
  conflicting reuse hold for **each** accepted part-2 operation; a missing
  reference to any part-2 referenced record class refuses; `CINST` commits
  **before** `CROUTE`, each under **its own `request_id`**, and reusing one
  identity for both is conflicting reuse;
  **C3 integration at instance admission (AC 7, 8, FC 14, 15):** invalid package
  **or** host trust **refuses with no `CINST`**, and Trust Plane unavailability
  **refuses with no `CINST`**;
  **authoritative halves** — **AC 9:** without an approved instance admission
  **no `CINST` exists**; **AC 17:** an expiry lapse **writes no authoritative
  record**; **AC 18 / FC 17:** a fresh advertisement after expired trust or
  admission **creates no revival and no admission record**; **AC 51 / FC 18:**
  host disappearance **changes no authoritative state**; **AC 69:** an expired
  admission causes **no Trust Plane write and no trust-label change**.
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
- **AC:** 8 (eligibility half), 9, 10, 13, 14, 17, 18, 42 (eligibility half), 51 (eligibility half), 56, 57, 58, 69 · **FC:** 16 (eligibility recomputation), 17, 18, 27
- **Dependency check:** **C5 accepts no Health Runtime input.** **AC 59, 60 and FC 28 move to increment 9**, where the Health input boundary lives.

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
  declared compatibility consulted; **stale or corrupt derived state is
  recomputed for eligibility**;
  **AC 8:** an unavailable Trust Plane makes eligibility **ineligible, fail
  closed, with no cached verdict**; **AC 9 and 10:** with admission absent the
  verdict names **the absent admission as the unmet condition**; **AC 14:**
  **non-overlapping package, host, and admission scopes** yield an empty
  effective intersection — not merely a generic ELIG-8 failure; **AC 17 and 18 /
  FC 17:** after trust, advertisement, or admission expiry the instance is
  ineligible and a **fresh advertisement does not restore eligibility**;
  **AC 51 / FC 18:** after host disappearance the instance is ineligible as a
  **derived** outcome only; **AC 69:** an expired admission yields ineligible
  **while package and host trust remain exactly what C3 reports**.
  **C5 accepts no Health input at all** — unknown-health and health-cannot-grant
  behaviour belong exclusively to C6 (increment 9).
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
- **AC:** 20, 21, 22, 23, 24, 26, 27, 35 (repeat, on `CSEL`), 36, 38, 42 (selection half), 50, 51 (selection half), 53, 54, 57 (repeat, selection boundary), 59, 60, 63 (repeat, on `CSEL`), 65, 76 (repeat, on `CSEL`), 77 (repeat, on `CSEL`), 80 · **FC:** 7, 8, 9, 16 (selection recomputation), 22, 23, 24, 26, 28
- **Red:** assert identical inputs choose identically across repeated runs; the
  **first** candidate in human-declared order wins with no reordering by any
  measurement; **ELIG-13** — a candidate absent from the route is excluded;
  **no route at all refuses with an outcome distinguishable from
  no-eligible-candidate**; no eligible candidate refuses naming **every**
  candidate and its exclusion; `local-only` refuses rather than degrading;
  health removes only, and **absent or unknown health removes, adds, promotes,
  and reorders nothing**; **health cannot grant trust, override quarantine,
  broaden scope, or admit a node**; **stale or corrupt derived state is
  recomputed for selection**; **ELIG-14** — a `side-effecting` contract is
  unroutable and **no route may override**; selection returns a Fabric identity
  or `CSEL` and **never invokes**; package contents never loaded; **a replayed
  accepted `CSEL` — selection, refusal, and no-candidate alike — returns its
  original outcome and `CSEL` identity**; **an accepted `CSEL` outcome is
  reconstructable from records alone** — route, route version, every candidate,
  each exclusion, and the outcome; and every accepted `CSEL` carries its
  complete §11 evidence (AC 35, 63).
  **`CSEL` replay across all three outcome classes — selection, refusal, and
  no-candidate (AC 76, 77, FC 7, 8, 9):** a **new** `request_id` with identical
  authoritative input creates an **independent `CSEL`**; **exact replay returns
  the original outcome and `CSEL` identity with no allocation**; **conflicting
  reuse fails as `request_identity_conflict`, creates no record, and leaves the
  original untouched**.
  **AC 51 / FC 18:** after host disappearance selection excludes the candidate
  and records the exclusion. **AC 57:** a request with no exactly compatible
  version **refuses at the selection boundary**, with no upgrade, downgrade,
  nearest match, or best-effort substitution.
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
- **AC:** 28, 29, 30, 33, 44, 47 · **FC:** 1 (repeat), 2 (repeat), 3 (repeat), 12
- **Dependency check:** inspection **reports** partial state; it performs no recovery, so **FC 25 moves to increments 11 and 12**.
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
- **AC:** 25, 43, 45 · **FC:** 25
- **Dependency check:** **AC 25 lands here** because it requires all of C1–C8 **and** the twelve-operation interface to exist.
- **Red:** **invoke every one of the twelve §8 operations with no Health Runtime
  present and assert each remains functional** — AC 25, assertable only now that
  C1–C8 and the interface all exist; assert each operation's required output
  fields and error categories (`refused`, `invalid`, `not-found`, `conflict`
  including `request_identity_conflict`, `unavailable`); no default store root;
  deterministic output; **explicit recovery produces new records by a new
  decision only** (FC 25); **a production-store digest and `ai/.env` comparison
  before and after the whole suite shows no change**.
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
- **AC (own Red):** 34, 74, 87 · **FC (own Red):** 8, 9, 12, 13, 25
- **Regression coverage:** every test introduced through increments 1–11 re-runs
  here via `tools/dev/run-validation.sh`. That is **regression coverage, not new
  Red** — the remaining failure conditions are **not** claimed as new
  observables in this increment.

**Replay lookup without a ledger.** Replay resolution searches the
`request_id`/`request_digest` evidence fields across **exactly the eight
accepted record types**. There is **no persistent request index, replay ledger,
or ninth record type**. The request-identity check and the accepted write are
**serialised through C1**; any lock or sequence artifact used for that
serialisation is **owned physically by C1 and is not a Fabric record**.

- **Red — concurrent writer losing the commit race (AC 34, FC 13):** with a
  deliberately synchronised competing writer targeting the **same allocated
  record path**, assert the loser receives a **storage conflict**, identifiers
  remain **unique and monotonic**, the original record is **byte-unchanged**,
  the conflict is **never reported as replay**, and **no silent overwrite**
  occurs.
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
- **Deterministic, non-deadlocking race protocol.** A barrier that releases only
  when **both** callers are inside the future critical section deadlocks the
  moment Green takes a lock before the replay lookup: the second caller can
  never arrive. The protocol therefore uses **latches released from outside**:

  1. The seam is an **overridable no-op hook** on `FabricStore`, introduced in
     **increment 2** so it exists before this Red runs. It has **no production
     behaviour** and creates **no persistent record**. The test may instead
     subclass and override the method purely test-side.
  2. Caller **A** is started; the test waits on `a_reached_hook`, signalled from
     inside the hook, then **A blocks on `a_release`**.
  3. Caller **B** is started. The coordinator waits until **B is observably
     blocked outside the critical section** — pre-fix it reaches the same hook
     and signals `b_reached_hook`; post-fix it blocks acquiring the request
     lock, detected by a bounded `b_blocked_on_lock` probe.
  4. The coordinator sets `a_release`. **The release never depends on B being
     inside the critical section**, so neither path can deadlock.
  5. Every wait is bounded; a timeout is a **test failure**, never a pass.

  **Pre-fix:** both callers observe *not found* on replay lookup, so the
  duplicate or conflict is exposed **on every run**. **Post-fix:** the request
  lock is **acquired before replay lookup and held through identity allocation
  and the accepted write**, so B completes without timeout, observes A's
  committed result, and returns **replay** or **`request_identity_conflict`** as
  appropriate. Both the **exact** and the **conflicting** same-`request_id`
  races are covered.
- **Observable Red reason:** with the protocol engaged, **both callers observe
  *not found* on replay lookup on every run**, so one `request_id` yields two
  accepted records — and, in the conflicting variant, two records for
  contradictory digests — instead of one record plus a replay or
  `request_identity_conflict`. The competing-writer variant additionally shows a
  **silent overwrite instead of a storage conflict**. No run times out.
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

## Dependency-order audit

Every increment obeys the controlling rule: **a Red assertion uses only
components delivered by an earlier increment or created in that same
increment**, and after each stated Green every test introduced so far plus
`tools/dev/run-validation.sh` passes.

| Increment | Components available | Components created | No forward dependency because |
|---|---|---|---|
| 1 | — | models, identifiers | asserts model shape only; no store, evidence, or accepted operation is referenced |
| 2 | models | C1 | allocation, modes, containment are store-local |
| 3 | models, C1 | C2 | **reports** stale, missing, malformed, or corrupt artifacts; recomputes nothing, because C5 and C6 do not exist |
| 4 | models, C1, C2 | C7 + identity | identity and evidence are **primitives**; end-to-end re-assertion waits for C4/C6 |
| 5 | models, C1, C2, C7 | C3 | **deterministic read-only verification results only**; it claims no admission refusal and no eligibility outcome — those are observable at C4 (6, 7) and C5 (8) |
| 6 | C1, C2, C3, C7 | C4 part 1 | declaration, subject admission, advertisement — **no C5 call** |
| 7 | C1–C3, C7, C4a | C4 part 2 | instance admission, lifecycle, routes — **no eligibility, no selection** |
| 8 | C1–C4, C7 | C5 | every eligibility scenario; **no Health input, no `CSEL`** |
| 9 | C1–C5, C7 | C6 | route membership, effect class, health removal, `CSEL` |
| 10 | C1–C7 | C8 | read-only inspection over C2 |
| 11 | C1–C8 | interface | the twelve operations, so AC 25 is assertable **here and not earlier** |
| 12 | everything, incl. the increment-2 no-op sync hook | — | the race protocol needs a seam that **already exists**; its Red claims only its own observables, the rest is regression |

**Criteria moved to remove forward dependencies:** AC 3, 5, 75 → 6 · AC 87 → 12
· AC 7, 8 → 6, 7, 8 (C3 alone proves neither refusal nor ineligibility) ·
AC 9 → 7 (authoritative) and 8 (eligibility) · AC 14, 17, 18, 69 → 7
(authoritative) and 8 (eligibility) · AC 51 → 7, 8, 9 · AC 42 → 8, 9 · AC 25 →
11 · AC 37 → 6, 7 · AC 55 → also 6 · AC 57 → also 9 · AC 59, 60 → 9 · AC 35, 63,
76, 77 → also 9 · FC 14, 15 → 6, 7 · FC 17, 18 → 7, 8 · FC 25 → 11, 12 · FC 28 →
9 · FC 7, 8, 9 → also 6, 9, 12.

## Coverage matrix — 87 acceptance criteria

Every entry points to an observable assertion in that exact increment's Red.

| Increment | Acceptance criteria |
|---|---|
| 1 | 32, 48, 55 |
| 2 | 1, 2, 4, 34, 39, 40, 41, 52, 68, 78 |
| 3 | 31, 32 |
| 4 | 35, 62, 63, 76, 77, 81, 82, 83, 84 |
| 5 | 46, 61, 71 |
| 6 | 3, 5, 6, 7, 8, 11, 12, 35, 37, 49, 55, 63, 64, 66, 67, 75, 76, 77, 79, 85, 86 |
| 7 | 7, 8, 9, 15, 16, 17, 18, 19, 35, 37, 49, 51, 63, 64, 69, 70, 72, 73, 76, 77, 79, 85 |
| 8 | 8, 9, 10, 13, 14, 17, 18, 42, 51, 56, 57, 58, 69 |
| 9 | 20, 21, 22, 23, 24, 26, 27, 35, 36, 38, 42, 50, 51, 53, 54, 57, 59, 60, 63, 65, 76, 77, 80 |
| 10 | 28, 29, 30, 33, 44, 47 |
| 11 | 25, 43, 45 |
| 12 | 34, 74, 87 |

**Coverage: 87/87.**

### Deliberate repeats, individually justified

| AC | Increments | Why each repetition exists |
|---|---|---|
| 7, 8 | 6, 7, 8 | Trust failure must refuse **subject** admission, refuse **instance** admission, and make eligibility fail closed — three different observables. C3 alone returns only a verdict |
| 9 | 7, 8 | Authoritative half (no `CINST` exists) and eligibility half (absent admission named as the unmet condition) |
| 17, 18 | 7, 8 | Expiry writes no authoritative record (C4); expiry removes eligibility (C5) |
| 32 | 1, 3 | Model-level version refusal, then refusal when a stored record is read |
| 34 | 2, 12 | Allocation and commit-race conflict at the store; then integrated under the deterministic race protocol |
| 35, 63 | 4, 6, 7, 9 | Evidence construction is a primitive; it must also hold on every accepted C4 record **and** on `CSEL` |
| 37 | 6, 7 | Zero-record rejection for part-1 and part-2 operations separately |
| 42 | 8, 9 | Derived staleness recomputed for eligibility **and** for selection |
| 49 | 6, 7 | Missing reference across part-1 and part-2 referenced record classes |
| 51 | 7, 8, 9 | Authoritative unchanged (C4), eligibility (C5), selection exclusion (C6) |
| 55 | 1, 6 | Model rejects a bad effect class; the **declaration operation** must refuse with zero records |
| 57 | 8, 9 | Version intersection in eligibility; refusal at the **selection boundary** |
| 64, 79, 85 | 6, 7 | Rejection and fresh re-evaluation for subject **and** instance admission |
| 69 | 7, 8 | No Trust Plane write (C4); ineligible while trust is unchanged (C5) |
| 76, 77 | 4, 6, 7, 9 | Replay and conflicting reuse as primitives, then integrated into every accepted operation class including all three `CSEL` outcomes |
| 78 | 2 | Collision-is-not-replay, proven once at the only component that allocates |

## Coverage matrix — 28 failure conditions

| Increment | Failure conditions |
|---|---|
| 1 | 4 |
| 2 | 1, 2, 6, 13, 19, 20, 21 |
| 3 | 3, 5, 16 |
| 4 | 7, 8, 9, 10 |
| 6 | 5, 7, 11, 14, 15 |
| 7 | 5, 11, 14, 15, 17, 18 |
| 8 | 16, 17, 18, 27 |
| 9 | 7, 8, 9, 16, 22, 23, 24, 26, 28 |
| 10 | 1, 2, 3, 12 |
| 11 | 25 |
| 12 | 8, 9, 12, 13, 25 |

**Coverage: 28/28.** Increment 5 owns no failure condition outright — C3 returns
a verdict, and the refusal it causes is observable only at C4 or C5.

**Repeats, justified:** FC 5 and 11 (6, 7 — part-1 and part-2 classes) · FC 7, 8,
9 (4, 6, 9, 12 — identity primitives, then declaration, then all three `CSEL`
outcomes, then the race protocol) · FC 13 (2, 12 — allocation conflict, then the
synchronised commit race) · FC 14, 15 (6, 7 — subject and instance admission) ·
FC 16 (3, 8, 9 — validator **reporting**, eligibility recomputation, selection
recomputation) · FC 17, 18 (7, 8 — authoritative and eligibility halves) · FC 1,
2, 3 (2, 3, 10 — store, validator, read-only inspection) · FC 12 (10, 12 —
reported by inspection, then produced by injection) · FC 25 (11, 12 — explicit
recovery through the interface, then integrated).

**Increment 12 claims only what its own Red observes.** Everything earlier
re-runs there as **regression coverage** via `tools/dev/run-validation.sh`, and
is not restated as new Red.

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

**No ninth persistent record type is introduced at any increment**, proven
observably by AC 87 in increment 12 against a fully exercised store.

## Persistent boundary assertion — AC 48

The repository-wide assertion introduced in **increment 1 runs in every
subsequent increment through 12**, so later interface or documentation work
cannot reintroduce what it forbids. It covers:

- **no execution adapter, worker, dispatcher, provider connector, invocation, or
  activation** anywhere under `tools/fabric/`
- **no Health evaluator and no Health-state computation** — C6 accepts a removal
  input and computes nothing
- **no remediation path** — no restart, redeploy, requeue, re-admission, drain,
  or quarantine

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

### PB-2 — the expected UID/GID rule is not determined by accepted sources

Increment 2 must refuse or report an **ownership** mismatch. Accepted sources
determine the **mode** rule but not the **ownership** rule. The
[Operator Root deployment guide](../../trust/operator-root-authority-deployment.md)
states:

> | Ownership | dedicated Kyri service account or approved operator |

and, in the same section, *"A service account is **not created** by this task."*

That is a **disjunctive role rule**, not a UID/GID a test can assert. No accepted
document names the service account, no registry of "approved operator"
identities exists, and no released code performs an ownership check — there is
no `chown`, `st_uid`, `st_gid`, `getuid`, or `geteuid` anywhere under `tools/`.

**Not invented here.** Until an operator decides the rule, increment 2:

- **captures and reports** `st_uid`/`st_gid` for the root, record directories,
  `sequences/`, sequence files, and record files as an observable finding;
- **never `chown`s, repairs, or corrects** ownership;
- asserts **no expected owner value**.

Everything mode-related is unaffected and fully testable: `0700` directories,
`0600` files, never world- or group-readable, and no symlinked store root — all
determined by the same accepted table.

**Nothing else is blocked.** The Gate 1 terminology question is resolved (§3),
and every other increment is derivable from ADR-0012, the accepted
specification, and the enumerated schema checks without inventing architecture.

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
