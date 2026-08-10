# ENG-0005 Capability Runtime Implementation Plan — Non-Executing Foundation

**Status:** Proposed — not accepted

> **For agentic workers:** Execute one increment at a time. Stop for independent
> review and explicit approval after each. **This plan authorises no
> implementation.** See §3.

**Goal:** Sequence the accepted
[ENG-0005 Capability Runtime specification](../specs/2026-08-10-capability-runtime-design.md)
into independently reviewable, test-first increments — **covering only the
functionality that cannot execute capability code.**

**Architecture:** Unchanged. Where this plan and the specification appear to
differ, **the specification governs.**

## 1. Controlling sources

1. [ENG-0005 Capability Runtime design](../specs/2026-08-10-capability-runtime-design.md) — **authoritative**
2. [ENG-0004 Fabric Runtime design](../specs/2026-08-04-fabric-runtime-design.md) — released substrate, `v0.10.0`
3. [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
4. [Fabric governance boundaries](../../fabric/governance-boundaries.md)

## 2. Why this plan stops short of execution

The specification authorises **no concrete adapter**. An adapter becomes
authorised only when its isolation boundary is demonstrated against §10.2, and
the [rootless execution prerequisite
design](2026-08-10-rootless-execution-prerequisite.md) is the separate track
that determines whether such a boundary can exist on this platform.

Everything below is the half of the runtime that does not depend on that
answer. It builds a coordinator that can do all the work up to the moment of
execution — resolve, verify, bind, record — and then **stops**.

**The absence of an adapter is a security property of this plan, not unfinished
work.** It is asserted, not assumed (§4).

## 3. Authorisation

This plan authorises nothing. Each increment requires its own explicit
authorisation, its own feature branch, its own review, and its own commit.
Implementation begins only when this plan is accepted **and** test-first entry
is separately authorised.

## 4. The hard no-execution boundary

The final state of this plan reaches `execution_prepared` and **must not cross
into `adapter_started`.**

**Forbidden in every increment:** any in-process callable adapter · any
subprocess, Docker, Podman, shell, or HTTP adapter · any placeholder or "fake
production" adapter capable of launching code · `exec`, `eval`, `importlib`,
`subprocess`, `os.system`, `os.exec*`, `os.posix_spawn`, `os.fork`,
`multiprocessing`, or any equivalent · reading or importing capability package
**contents**.

Verifying an artefact's bytes is reading a **file**; loading or running those
bytes is executing a **package**. This plan does the first and never the
second.

Test doubles are permitted only where they **cannot cause external capability
execution** — a double that returns a canned outcome is acceptable; a double
that launches anything is not.

**Proof strategy — three independent layers:**

1. **Static scan** over `tools/capability/` forbidding every construct listed
   above, in the shape of the released ENG-0004 increment-9 assertion.
2. **Runtime assertion** that the coordinator's terminal state is
   `execution_prepared`, that no adapter is registered, and that a prepared
   invocation refuses at the adapter boundary with a named reason.
3. **Filesystem forensics** proving a prepared-then-refused invocation leaves
   the staging area, the execution store, and the Fabric store exactly as it
   found them apart from the records the specification requires.

## 5. Boundaries that hold in every increment

- **Fabric reads only.** The runtime opens the Fabric store read-only and
  writes no Fabric record, ever.
- **No C5, no C6.** Preconditions are facts about records, never eligibility or
  selection.
- **No Trust call** on the invocation path.
- **No Health** input, derivation, or output.
- **No Fabric request lock** acquired at any point.
- **No `tools/fabric/` change.** ENG-0004 is released substrate.

## 6. Increments

### Increment A1 — Capability Runtime immutable store

**Objective.** A second immutable store, in its own plane, owing the Fabric
nothing but its discipline.

- **Created:** `tools/capability/store.py`, `tools/capability/errors.py`,
  `tools/capability/identifiers.py`
- **Inspect first:** `tools/common/immutable_store.py`, `tools/fabric/store.py`
- **Red:** explicit root and expected UID/GID with no default; `0o700`/`0o600`;
  ownership mismatch refuses and never `chown`s; symlinked root, record
  directory, or record refused; containment enforced through
  `tools/common/containment`; identifiers `CINV-[0-9]{6}` and `CRES-[0-9]{6}`
  allocated monotonically and uniquely under concurrency; sequence exhaustion
  refuses rather than rolling over; atomic write via exclusive temporary
  creation; a **pre-existing temporary is preserved and reported**, never
  truncated; a corrupt record refuses rather than being repaired; its critical
  section is **its own**, and acquiring it never touches the Fabric lock.
- **Observable Red reason:** `ModuleNotFoundError: No module named
  'tools.capability.store'`.
- **Green:** the store, built on `ImmutableStore`, adding refusal.
- **Excluded:** every record model; anything that reads Fabric.
- **Commit:** `feat(capability): add the capability runtime store`
- **Review checkpoint:** reviewer confirms the store shares no lock, no
  directory, and no identifier space with the Fabric store.
- **Rollback:** delete the modules.

### Increment A2 — Invocation identity and payload binding

**Objective.** Make one payload provably the payload the invocation was for.

- **Created:** `tools/capability/invocation_identity.py`
- **Inspect first:** `tools/fabric/request_identity.py`
- **Red:** `invocation_id` validated only as far as safety requires — bounded
  length, printable ASCII, constant-time comparison — and **never parsed**;
  canonical form is UTF-8 JSON, keys sorted by code point, no insignificant
  whitespace, no trailing newline, literal non-ASCII; floats, duplicate keys,
  unordered sets, and locale-dependent formatting **refuse**; the digest is
  `sha256:<hex>` over the payload **and** the binding tuple
  (`invocation_id`, `selection_id`, `instance_id`, `capability_package_id`,
  `actor`); identical logical payloads digest identically across processes and
  hash seeds; any single change to payload or binding changes the digest; a
  duplicate identity with identical binding yields `invocation_identity_consumed`
  and a different binding yields `invocation_identity_conflict`; the helper
  **never enters a critical section** and writes nothing.
- **Observable Red reason:** `ModuleNotFoundError`.
- **Green:** canonicalisation, digest, and identity comparison.
- **Excluded:** persistence; any Fabric read.
- **Commit:** `feat(capability): bind execution payloads to their invocation`
- **Review checkpoint:** reviewer confirms nothing parses `invocation_id` and
  the digest covers the binding, not just the payload.
- **Rollback:** delete the module.

### Increment A3 — Fabric evidence reader and precondition evaluator

**Objective.** Read the governed decision. Judge facts, never eligibility.

- **Created:** `tools/capability/fabric_evidence.py`,
  `tools/capability/preconditions.py`
- **Inspect first:** `tools/fabric/inspection.py`, `tools/fabric/store.py`
  (`open_for_read`)
- **Red:** the Fabric store is opened **read-only** and the reader has no write
  path at all; preconditions 1–6 and 9 of specification §6 each refuse
  independently and name their own reason; a `CSEL` recording a refusal
  executes nothing; a caller-supplied instance identity is **refused** — the
  instance comes from the `CSEL`; an incoherent record chain fails closed; a
  `side-effecting` contract refuses; **no `evaluate_eligibility` and no
  `select_candidate` import exists anywhere in `tools/capability/`**; no Trust
  import; no Fabric write; every refusal leaves both stores byte-unchanged.
- **Observable Red reason:** `ModuleNotFoundError`.
- **Green:** the reader and the fact-guards.
- **Excluded:** artefact resolution (A4); persistence (A5).
- **Commit:** `feat(capability): evaluate execution preconditions`
- **Review checkpoint:** reviewer confirms no precondition is expressed as
  "still eligible" and that C5/C6 are unreachable from this package.
- **Rollback:** delete the modules.

### Increment A4 — Executable package resolution and integrity

**Objective.** Turn a governed package into verified bytes, or refuse.

- **Created:** `tools/capability/package_resolution.py`
- **Inspect first:** `tools/common/containment.py`,
  `tools/integrity/snapshot_manager.py` (the released `sha256:` convention)
- **Red:** only `file:<relative-path>` resolves; free text, `oci://`, `https://`,
  and every other scheme **refuse**; traversal, absolute escape, symlink escape,
  sibling-prefix, and the approved directory itself refuse through the shared
  primitive; a `CPKG` with **no `manifest_reference` refuses**; a manifest
  without a `sha256` digest refuses; a digest mismatch refuses as
  **substitution detected**; the artefact is opened **once** and the digest
  computed **from that descriptor**; staging is content-addressed by the
  verified digest, mode `0700`, created atomically, and a colliding stage with
  different bytes refuses; **`package_version` is never treated as a digest**;
  an optional `signature_reference` is never read as evidence of verification;
  nothing is executed, imported, or loaded — only read and hashed.
- **Observable Red reason:** `ModuleNotFoundError`.
- **Green:** grammar, containment, manifest validation, verification, staging.
- **Excluded:** mounting, launching, adapters.
- **Commit:** `feat(capability): resolve and verify executable packages`
- **Review checkpoint:** reviewer confirms verified bytes and staged bytes come
  from one descriptor, and that no code path imports or runs artefact content.
- **Rollback:** delete the module and the staging root.

### Increment A5 — Invocation, refusal evidence, and replay

**Objective.** Durable evidence of what was attempted, before anything is.

- **Created:** `tools/capability/records.py`, `tools/capability/evidence.py`
- **Red:** the invocation record is written **before** any adapter boundary is
  reached; a refusal at any precondition persists a refusal record naming the
  reason and **allocates nothing further**; replay returns the original record
  and re-prepares nothing; conflicting reuse refuses; an invocation with no
  result is reported **interrupted** by validation and is **never cleaned**;
  records carry no secret material and no unbounded payload — payloads appear
  as digests; every record links invocation identity, Fabric `request_id`,
  `CSEL`, `CINST`, `CPKG`, actor, payload digest, effect class, and artefact
  digest.
- **Observable Red reason:** `ModuleNotFoundError`.
- **Green:** record models and evidence assembly.
- **Excluded:** result records for executions that cannot occur — only
  preparation and refusal outcomes exist in this plan.
- **Commit:** `feat(capability): record invocation and refusal evidence`
- **Review checkpoint:** reviewer confirms evidence ordering and that no record
  can carry a payload body.
- **Rollback:** delete the modules.

### Increment A6 — Inspection, validation, and the CLI that refuses

**Objective.** An operator surface that can prepare an invocation and prove it
stopped.

- **Created:** `tools/capability/inspection.py`, `tools/capability/cli.py`,
  `tools/capability/coordinator.py`
- **Red:** `inspect` and `validate` are read-only, deterministic, and repair
  nothing; the coordinator runs preflight → preconditions → resolution →
  verification → staging → invocation record and terminates at
  `execution_prepared`; `invoke` reaches the adapter boundary and **refuses
  with `no_authorised_adapter`**, exit code denied, having written its
  invocation record and staged its artefact; **no adapter registry contains an
  entry**; the Fabric CLI is unchanged and still has no execution verb; C8 is
  unchanged; the static scan of §4 passes; forensics show the Fabric store
  byte-unchanged across every command.
- **Observable Red reason:** `ModuleNotFoundError`.
- **Green:** inspection, validation, coordinator, CLI.
- **Excluded:** any adapter.
- **Commit:** `feat(capability): add the capability runtime interface`
- **Review checkpoint:** reviewer confirms `invoke` cannot execute anything and
  that the refusal is a named architectural state, not an error.
- **Rollback:** delete the modules.

### Increment A7 — Boundary proof and closure

**Objective.** Make the absence of execution a tested property.

- **Changed:** tests only; documentation.
- **Red:** the three proof layers of §4 asserted together — static scan over
  every module in `tools/capability/`; runtime assertion that no production
  path reaches an adapter; forensics over a full prepare-and-refuse cycle;
  plus the regression battery at or above the ENG-0004 baseline.
- **Green:** none — this increment adds no production behaviour. Its Red is the
  proof, and it must fail if any earlier increment introduced a way to execute.
- **Docs:** ENG-0005 status in the engineering ledger.
- **Commit:** `test(capability): prove no execution path exists`
- **Review checkpoint:** reviewer confirms the boundary is proven by test rather
  than by inspection of the diff.

## 7. Acceptance criteria mapped to increments

| Specification AC | Increment |
|---|---|
| 1–5 authority | A3, A6 |
| 6–8 invocation identity | A1, A2 |
| 9–12 payload binding | A2 |
| 13–14 package resolution | A4 |
| 15–17 integrity | A4 |
| 18, 20, 20a, 20b execution/containment | A6, A7 (as refusals — nothing executes) |
| 19 no command construction | A4, A6, A7 |
| 21–22 effect class | A3 |
| 23–25 replay | A2, A5 |
| 26–28 failure | A3, A4, A5 |
| 29–31 persistence | A1, A5 |
| 32–34 crash | A5 |
| 35–36 secrets | A3, A6 (refusal path only) |
| 37–38 lock isolation | A1, A7 |
| 39–41 Health and Trust separation | A3, A7 |
| 42–44 inspection and CLI | A6 |

**Deferred to the adapter increment, which this plan does not contain:** every
criterion whose subject is a running capability.

## 8. Failure criteria mapped to increments

| Specification FC | Increment |
|---|---|
| F1–F3 forged/bypassed selection | A3 |
| F4 payload swapped after digest | A2, A6 |
| F5 artefact swapped after verification | A4 |
| F6–F8 traversal, absolute, symlink | A4 |
| F9 manifest digest mismatch | A4 |
| F10 `side-effecting` presented | A3 |
| F11–F12 identity replay and reuse | A2, A5 |
| F13–F14 capability calling Fabric or taking its lock | **deferred** — needs a running capability |
| F15 capability reading outside the directory | **deferred** |
| F16 secret in payload | A2, A5 |
| F17 oversized result | **deferred** |
| F18 unserialisable result | **deferred** |
| F19–F20 withdrawn instance, expired window | A3 |
| F21 crash between effect and write | A5 (interruption reporting only) |
| F22 execution evidence in the Fabric store | A1, A7 |

## 9. Validation gates

Every increment: `bash tests/test-capability-runtime.sh` (new, created in A1),
`bash tests/test-fabric-runtime.sh` (must stay at or above **8017 / 0 / 0**),
`tools/dev/run-shellcheck.sh`, `pre-commit run --all-files`, and
`tools/dev/run-validation.sh` at **34/34**. Runtime output byte-identical
across two runs. No accepted assertion count may decrease.

## 10. Stop points

Stop and report, without proceeding, if: an increment cannot be completed
without executing artefact content · a precondition cannot be evaluated without
C5 or C6 · evidence cannot be written without a Fabric write · the staging
design cannot preserve verified-bytes-equal-executed-bytes · or the
specification is found to require an architecture decision it does not contain.

## 11. Unresolved dependencies

1. **No authorised adapter.** Gates every executing increment; owned by the
   rootless execution prerequisite design.
2. **Secret broker undefined.** Not on this plan's path — unresolved secret
   references refuse.
3. **Result records** are specified but only the interrupted and refused cases
   are reachable here; the completed case arrives with the adapter.

## 12. Related records

- [ENG-0005 Capability Runtime design](../specs/2026-08-10-capability-runtime-design.md)
- [Rootless execution prerequisite design](2026-08-10-rootless-execution-prerequisite.md)
- [ENG-0004 Fabric Runtime design](../specs/2026-08-04-fabric-runtime-design.md)
- [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)
