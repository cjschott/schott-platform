# ENG-0005 First Adapter Implementation Plan — Bounded Local Python Execution

**Status:** Proposed — not accepted

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

> **This plan authorises no implementation.** Execute one task at a time and
> stop for independent review after each. Every reviewer gate in §5 is a hard
> stop, not a formality.

**Goal:** Implement the accepted
[first adapter specification](../specs/2026-08-11-first-adapter-design.md) —
bounded local Python execution under rootless Podman — as independently
reviewable, test-first increments, without ever letting production code lead
its tests.

**Architecture:** A coordinator (`cschott`) reserves capacity, verifies
evidence, publishes a per-invocation handoff, and remains the sole writer of
authority state. One root-owned helper validates a single `CINV`, prepares
ownership, and drops permanently to `kyri-capability`, which runs an
unprivileged worker that drives rootless Podman `create`/`start` and reports
observations back over inherited descriptors. No daemon, no socket, no API, and
no value but `CINV-nnnnnn` crosses the privilege boundary.

**Tech Stack:** Python 3.12 standard library only (no third-party runtime
dependencies, matching `tools/capability/`); Bash test suites in the existing
`tests/test-*.sh` style; rootless Podman 4.9.3 with runc 1.3.6; sudo 1.9.15p5;
XFS on `/data`; ShellCheck 0.9.0 and the repository `pre-commit` hooks.

## 1. Global constraints

Copied from the specification. Where this plan and the specification differ,
**the specification governs.**

- The only value crossing the privileged boundary is `CINV-nnnnnn`; the
  caller-supplied `invocation_id` never crosses it.
- Root never runs Podman, never opens a caller-supplied path, never constructs
  container argv from caller input, and exposes no shell or generic user-switch.
- The execution identity never writes authority state. Authority roots are
  `0700 cschott:cschott`.
- **One transition per invocation.** Coordinator and worker exchange
  newline-delimited canonical JSON over inherited descriptors, closed grammar,
  64 KiB per message; violations are `execution_protocol_violation`.
- `podman create` then `podman start`. **Never `podman run`.**
- Profile is adapter-owned and fixed: `--network none`, `--read-only`,
  `--cap-drop ALL`, `no-new-privileges`, no devices, 16 MiB `noexec,nosuid,nodev`
  `/tmp`, memory 256 MiB, memory-swap 256 MiB, CPU 0.5, PIDs 64, wall timeout
  30 s, grace 2 s, global concurrency 2.
- Payload: read-only file at `/run/kyri/input/payload`, canonical UTF-8 JSON,
  one top-level object, duplicate keys rejected at any depth, signed 64-bit
  integers only, no fractions or exponents, reject U+0000 and unpaired
  surrogates, no normalisation, 2 MiB max. Never argv, never environment.
- Result: `/kyri/output/result.json`, one JSON object, 2 MiB max, never
  repaired. Success requires start proven, valid terminal lifecycle, no
  timeout, no policy violation, exit 0, valid result, and a valid complete
  output tree. **Timeout always fails.**
- Output tree: 32 regular files, 16 MiB aggregate, 2 MiB per file, stdout and
  stderr 2 MiB each with independent `truncated=true`. Collector is
  descriptor-relative and no-follow, regular files only, rejecting symlinks,
  hard-link anomalies, FIFOs, sockets, devices, traversal, absolute paths, and
  directory-rename escape. **Any output-policy violation fails the invocation;
  a valid result never overrides it.**
- Lifecycle precedes `ExitCode`, always. `Created` with exit 0 is a
  never-started launch failure.
- Once `reserved` is durably committed the `CINV` is permanently consumed. **No
  automatic retry, replay, or re-execution anywhere.**
- Lock order: global capacity → per-`CINV`. Never invert.
- Every authority-bearing mutation is CMUT-covered; CMUT recovery is **out of
  scope** and is a stop condition if it appears necessary.
- No pull during invocation. The exact digest must already exist in the
  rootless store. **The Track-B Alpine digest is TEST-ONLY and never promoted.**
- Secret-free; `--network none`; no devices or GPU. Each requires separate
  governance.
- No new filesystem root inherits a mode by convention (Deferred G).

## 2. Controlling sources

1. [First adapter design](../specs/2026-08-11-first-adapter-design.md) — **authoritative**
2. [Execution transition boundary](../specs/2026-08-11-execution-transition-boundary.md) — accepted
3. [Capability Runtime design](../specs/2026-08-10-capability-runtime-design.md) — released substrate
4. [Rootless execution prerequisite](2026-08-10-rootless-execution-prerequisite.md) — Track-B evidence

## 3. File map

Every path is reconstructed from existing repository conventions
(`tools/capability/`, `tools/common/`, `tests/test-*.sh`,
`tools/dev/`).

**Created — production**

| Path | Purpose |
|---|---|
| `tools/capability/execution/__init__.py` | adapter package root |
| `tools/capability/execution/types.py` | immutable execution domain types |
| `tools/capability/execution/canonical_json.py` | canonical JSON parse/serialise |
| `tools/capability/execution/payload.py` | payload validation and binding |
| `tools/capability/execution/implementation_authority.py` | CIMP/CGEN read-only consumer |
| `tools/capability/execution/mutation.py` | CMUT interface |
| `tools/capability/execution/backing_store.py` | backing-store verification |
| `tools/capability/execution/state.py` | lifecycle state records |
| `tools/capability/execution/capacity.py` | slot reservation and lock hierarchy |
| `tools/capability/execution/package_contract.py` | package + entrypoint validation |
| `tools/capability/execution/handoff.py` | per-invocation handoff publication |
| `tools/capability/execution/profile.py` | fixed Podman profile + fingerprint |
| `tools/capability/execution/protocol.py` | coordinator↔worker message schema |
| `tools/capability/execution/worker.py` | unprivileged worker |
| `tools/capability/execution/lifecycle.py` | create/verify/start/terminal classification |
| `tools/capability/execution/collector.py` | result and output-tree collector |
| `tools/capability/execution/quarantine.py` | forensic quarantine + reservations |
| `tools/capability/execution/cleanup.py` | cleanup and recovery |
| `tools/capability/execution/admin.py` | administrative reconciliation, CADM |
| `tools/capability/execution/adapter.py` | the adapter satisfying design §9 |

**Created — host-provisioning-only (never installed by tests)**

| Path | Purpose |
|---|---|
| `provisioning/execution/kyri-exec-transition.py` | transition helper source |
| `provisioning/execution/kyri-exec-worker.py` | worker script source, installed mode 0444 |
| `provisioning/execution/kyri-exec-admin.py` | administrative helper source |
| `provisioning/execution/sudoers.d/kyri-exec.example` | reviewed sudoers example, not installed |
| `provisioning/execution/backing-store.json.example` | backing-store config example |
| `provisioning/image/Containerfile` | production Python image definition |
| `provisioning/image/README.md` | image build and admission procedure |

**Created — tests**

`tests/test-capability-execution.sh` · `tests/test-capability-execution-lifecycle.sh` ·
`tests/test-capability-execution-collector.sh` ·
`tests/test-capability-execution-admin.sh` ·
`tests/test-capability-execution-integration.sh` ·
`tests/test-capability-execution-failure-injection.sh`

**Modified**

`tools/capability/cli.py` (invoke reaches the adapter) ·
`tools/capability/coordinator.py` (reserve → authorise → transition) ·
`tools/capability/errors.py` (new classifications) ·
`tests/test-capability-runtime.sh` (backstop updated to assert the *only*
execution path is this adapter) · `tools/dev/run-validation.sh` (new suites)

**Documentation-only**

`docs/history/v1.0-engineering-ledger.md` · `docs/superpowers/specs/2026-08-11-first-adapter-design.md`

## 4. Tasks

Each task is reviewer-sized and independently testable. Steps are always:
write failing test → run RED → implement minimal behaviour → run GREEN → run
regression set → commit.

Regression set unless stated otherwise:
`bash tests/test-capability-runtime.sh && bash tests/test-capability-fabric.sh && bash tests/test-docs-static.sh`

### T1 — Immutable execution domain types

**Files:** `tools/capability/execution/{__init__,types}.py`,
`tests/test-capability-execution.sh`
**Interfaces:** `ExecutionProfile`, `ExecutionFingerprint`, `LifecycleState`,
`Classification`, `SlotReservation` — frozen dataclasses; `Classification.of(reason: str) -> Classification`.

- Write failing test: types are frozen, reject unknown fields, and every §25
  classification string is present exactly once.
- **RED:** `ModuleNotFoundError: No module named 'tools.capability.execution.types'`
- Implement the types only. No behaviour.
- **GREEN:** `bash tests/test-capability-execution.sh`
- Regression set.
- **Commit:** `feat(execution): add immutable execution domain types`

### T2 — Canonical JSON

**Files:** `tools/capability/execution/canonical_json.py`
**Interfaces:** `parse(data: bytes, *, maximum_bytes: int) -> dict`,
`serialise(value: dict) -> bytes`

- Failing tests: duplicate keys at depth 3 rejected; floats, exponents, NaN,
  Infinity rejected; integers outside int64 rejected; U+0000 rejected; unpaired
  surrogates rejected; no NFC normalisation applied; key ordering is
  deterministic UTF-8 byte order; oversize rejected before parse completes.
- **RED:** `AssertionError: duplicate key at depth was accepted`
- Implement using `json.loads(object_pairs_hook=…)` with a rejecting hook.
- **GREEN**, regression set.
- **Commit:** `feat(execution): add canonical JSON with closed grammar`

### T3 — Payload contract

**Files:** `tools/capability/execution/payload.py`
**Interfaces:** `validate_payload(descriptor: int, *, schema_version: int) -> PayloadBinding`

- Failing tests: 2 MiB bound; top-level non-object rejected; schema closed,
  unknown field rejected; schema version immutable at authorisation; digest
  recomputed from the descriptor, never from a path.
- **RED:** `ModuleNotFoundError: … .payload`
- **GREEN**, regression set.
- **Commit:** `feat(execution): bind and validate the canonical payload`

### T4 — CIMP/CGEN read-only authority consumer

**Files:** `tools/capability/execution/implementation_authority.py`
**Interfaces:** `current_generation(root_fd: int) -> Generation`,
`resolve_implementation(root_fd: int, cimp: str, *, generation: Generation) -> Admission`

> **Interface amended 2026-08-11, before implementation.** The original
> signatures took `root: Path`. A pathname is re-resolved on every use, so the
> authority root would not be anchored and the "root replacement cannot
> redirect an anchored validation" property would be unprovable; it would also
> make this the first module in the package to hold path authority, in the
> component that decides what may execute. The reviewer's T4 ruling requires an
> already-open trusted directory descriptor, so both signatures now take
> `root_fd`, matching the T3 precedent `validate_payload(descriptor: int, …)`.
> Recorded here rather than changed silently in the implementation commit.

- Failing tests: grammar `^CIMP-[0-9]{6}$` and `^CGEN-[0-9]{12}$`; genesis is
  the only null-predecessor generation; authority-set digest must match the
  generation record; snapshot invalidated on any generation mismatch; 10,000
  entry and 2 MiB bounds enforced with **every** entry counted; scan overflow →
  `implementation_authority_scan_limit_exceeded`; summary overflow →
  `implementation_authority_findings_truncated`; both imply
  `implementation_authority_integrity_failure`; retired CIMP refuses new
  binding; **no write path exists in this module** (asserted by discovery).
- **RED:** `AssertionError: retired CIMP was bound`
- **GREEN**, regression set.
- **Commit:** `feat(execution): consume governed implementation authority`

### T5 — Backing store + CMUT interface

**Files:** `tools/capability/execution/{backing_store,mutation}.py`
**Interfaces:**
`verify_backing_store(config_fd: int, root_fd: int, *, observed: ObservedFilesystem) -> RootDescriptor`,
`Mutation.begin(target: MutationTarget, *, schema_type: str, expected_sha256: str) -> str`,
`Mutation.install(cmut: str, body: bytes) -> None`,
`Mutation.commit(cmut: str) -> None`,
`Mutation.recover(root_fd: int) -> tuple[UnknownOutcome, ...]`

> **Interface amended 2026-08-11, before implementation.** Authority-bearing
> writes and their recovery must stay anchored to trusted filesystem objects,
> so nothing re-resolves a mutable pathname after trust is established.
>
> - **Was** `verify_backing_store(config: Path, root: Path)`; **now** both are
>   already-open descriptors. A third input, `observed`, is required by a
>   concrete runtime limitation: **Python exposes no way to obtain a filesystem
>   UUID from a directory descriptor.** `os.fstat` yields `st_dev` and
>   `os.statvfs` yields no UUID, so UUID and mount facts must be observed by
>   the caller — which already holds that authority — and passed as an
>   immutable value. T5 then binds the *descriptor's* `st_dev` itself, so the
>   mutation transaction is anchored to the descriptor rather than to the
>   caller's claim.
> - **Was** `Mutation.recover(root)`; **now** `recover(root_fd)`. Recovery
>   derives only canonical child names from validated CMUT identities.
> - **`target` was unannotated.** It is now the closed `MutationTarget` value:
>   a kind from a fixed enum plus a name matching that kind's canonical
>   grammar. No caller-supplied string, `Path`, absolute path, traversal, or
>   unvalidated component can reach the filesystem. The plan left this open
>   rather than modelling it as free-form, so it is closed here rather than
>   reported as a conflict.
> - **`install` was missing.** The plan named `begin` and `commit` but no
>   installation step, while requiring at-most-one installation attempt. The
>   step is now explicit so "at most once" is enforceable at a named boundary.
>
> **Descriptor ownership and lifetime.** Callers retain ownership of every
> descriptor they pass; T5 never closes a caller's descriptor. `RootDescriptor`
> holds a **duplicate** of `root_fd`, made with `os.dup`, so the verified root
> survives independently of the caller's lifetime and cannot be invalidated by
> the caller closing theirs. The duplicate is released by `RootDescriptor.close()`.
> Any pathname in returned metadata is diagnostic only and is never used to
> reopen, locate, recover, install, or fsync.
>
> No specification semantics change; only the interfaces do.

- Failing tests: UUID and type mismatch → `quarantine_backing_store_mismatch`;
  config integrity mismatch → `…_config_integrity_failure`; device name changes
  are diagnostic and do **not** fail; descriptor identity reverified after
  mutation; intent-without-outcome yields unknown, never replay; recovery
  requires exact SHA-256 equality; journal corruption →
  `mutation_journal_integrity_failure` freezing new mutations while permitting
  read-only observation; the CMUT layer is exempt from recursive coverage.
- **RED:** `ModuleNotFoundError: … .mutation`
- **GREEN**, regression set.
- **Commit:** `feat(execution): add backing-store and CMUT durability interface`

### T6 — Capacity, locks, lifecycle state

**Files:** `tools/capability/execution/{state,capacity}.py`
**Interfaces:**
`current_state(root: RootDescriptor, cinv: str) -> LifecycleState | None`,
`transition(root: RootDescriptor, cinv: str, frm: LifecycleState, to: LifecycleState) -> None`,
`reserve(root: RootDescriptor, cinv: str) -> SlotReservation`,
`release(root: RootDescriptor, reservation: SlotReservation) -> None`

> **Interface amended 2026-08-11, before implementation.** Capacity and
> lifecycle state are authority-bearing, so they stay anchored to the T5
> verified backing-store object instead of to a root that could be re-resolved.
>
> - **Was** `reserve(root, cinv)`, `release(reservation)`, `transition(cinv,
>   frm, to)` — `root` unannotated and absent entirely from the latter two.
>   **Now** every authority-bearing operation takes the T5-verified
>   `RootDescriptor` first. No pathname parameter is introduced anywhere as a
>   workaround.
> - **Descriptor lifetime** follows T5: callers own what they pass, T6 closes
>   nothing it did not open, and no raw fd integer is ever persisted as durable
>   state.
> - **Lock order is `global capacity → per-CINV`, never inverted.** A path
>   already holding a CINV lock must not acquire the capacity lock.
>
> **State is append-only, and that follows from T5 rather than from taste.**
> `Mutation.install` is create-once: it refuses a target that already exists,
> deliberately, so a single mutable state file per CINV cannot work. Each
> transition is therefore its own immutable record, and the current state is
> the last record of a validated contiguous chain. This also matches the
> immutable-store discipline used everywhere else in the runtime.
>
> Recording a transition needs a sequenced target name, which the existing
> `TargetKind.EXECUTION_STATE` grammar (`CINV-nnnnnn`) cannot express, so T6
> adds `TargetKind.EXECUTION_TRANSITION` with grammar
> `CINV-nnnnnn.nnnnnn` under `transitions/`. That is an additive extension of
> the T5 substrate at its intended extension point — not a second write
> protocol, which the ruling forbids.

- Failing tests: two slots granted, third → `execution_capacity_exhausted`;
  `reserved` consumes the `CINV` permanently with no rollback; lock order
  global→per-`CINV` enforced and inversion raises; locks are advisory and carry
  no durable authority; lock files live outside authority namespaces; file
  existence carries no lifecycle meaning; every transition is CMUT-covered;
  authority roots are `0700` and refuse a wrong owner.
- **RED:** `AssertionError: third reservation was granted`
- **GREEN**, regression set.
- **Commit:** `feat(execution): add capacity reservation and lifecycle state`

### T7 — Package contract and handoff publication

**Files:** `tools/capability/execution/{package_contract,handoff}.py`
**Interfaces:**
`validate_package(descriptor: int, *, entrypoint: str) -> PackageBinding`,
`publish_handoff(root: RootDescriptor, cinv: str, artefact_fd: int, payload: PayloadBinding, package: PackageBinding) -> HandoffBinding`

> **Interface amended 2026-08-11, before implementation.** Handoff publication
> writes security-critical execution input, so it is anchored to a verified
> descriptor rather than to a name.
>
> - **`publish_handoff` had no destination authority at all** — it named a
>   `CINV` and some bytes with nothing to write them through. It now takes the
>   T5-verified `RootDescriptor` first, as T6 established for every
>   authority-bearing runtime interface.
> - **`payload_bytes` becomes `payload: PayloadBinding`.** Proving the
>   published bytes match the T3 digest requires the digest, and only the
>   binding carries it. Raw bytes could prove equality with themselves and
>   nothing more.
> - **`validate_package` gains `entrypoint`.** The governed entrypoint comes
>   from capability metadata and must be validated against the tree; the
>   original signature had nowhere to supply it.
> - **`HandoffRoots` becomes `HandoffBinding`.** What it carries is identity —
>   digests proving what was published — not a set of directories.
>
> **`descriptor: int` is retained for `validate_package` and expresses the tree
> correctly**: it is an already-open *directory* descriptor, and `os.scandir`
> enumerates it descriptor-relatively. No pathname tree is invented, and no
> conflict exists to report.
>
> `artefact_fd` is the verified package-tree descriptor whose contents are
> copied. Descriptor ownership follows T5: callers own what they pass.

- Failing tests: 64 MiB / 1,024 entries / 16 MiB per file; native extension,
  ELF, `.so`, and non-`.py` entrypoint rejected; traversal and symlink escape
  rejected; exactly one entrypoint, no discovery; copy not hard link (link
  count asserted to be 1); publication is `rename`-atomic and digest is
  re-verified after publication; existing `<CINV>` handoff refuses; modes match
  the §13 table exactly.
- **RED:** `AssertionError: hard link aliased the canonical inode`
- **GREEN**, regression set.
- **Commit:** `feat(execution): validate packages and publish invocation handoff`

### T8 — Fixed profile and fingerprint

**Files:** `tools/capability/execution/profile.py`
**Interfaces:** `build_profile(binding) -> ExecutionProfile`,
`fingerprint(profile) -> ExecutionFingerprint`, `verify_observed(profile, observed) -> None`

- Failing tests: argv is byte-exact and contains no caller-derived element;
  capability metadata attempting to set network, image, mounts, devices, caps,
  or resources **refuses** rather than being ignored; fingerprint persists both
  canonical digest and explicit security-critical fields; `verify_observed`
  requires exact agreement on every §17 field and raises
  `execution_identity_mismatch` otherwise; unknown `profile_schema_version` →
  `execution_profile_version_unsupported`; missing verifier →
  `execution_profile_verifier_unavailable`.
- **RED:** `AssertionError: capability metadata influenced the profile`
- **GREEN**, regression set.
- **Commit:** `feat(execution): freeze the adapter-owned runtime profile`

### T9 — Coordinator↔worker protocol

**Files:** `tools/capability/execution/protocol.py`
**Interfaces:** `encode(message) -> bytes`, `decode(line: bytes) -> Message`,
`Session.expect(kind) -> Message`

- Failing tests: closed grammar, unknown field rejected; >64 KiB rejected;
  out-of-order message → `execution_protocol_violation`; a message is never
  executed, only validated as data; worker cannot express any authority claim
  the schema does not carry.
- **RED:** `AssertionError: out-of-order message accepted`
- **GREEN**, regression set.
- **Commit:** `feat(execution): add the coordinator-worker protocol`

### T10 — Transition helper: pure policy, unprivileged

**Files:** `provisioning/execution/kyri-exec-transition.py` (policy functions only)
**Interfaces:** `validate_cinv(arg: str) -> str`,
`evidence_path(cinv: str) -> Path`,
`check_launch_authorisation(record: dict) -> None`,
`policy_for(argv: Sequence[str]) -> TransitionPolicy`

> **Interface amended 2026-08-11, before implementation.** `evidence_path` took
> a `root: Path`, which contradicted the plan's own T10 prose, §6 of the design
> ("construct the evidence pathname itself from a compiled-in root"), and the
> T10 ruling ("the caller never supplies… evidence path"). The parameter is
> **removed** rather than replaced with a descriptor: the root helper runs
> before any verified descriptor exists, so the compiled-in constant *is* the
> trust anchor. `policy_for` is named because the CLI grammar and the immutable
> policy result are T10 deliverables that the original three signatures had
> nowhere to express.

- Failing tests, run **entirely unprivileged**: grammar rejects
  `CINV-00004`, `CINV-0000042`, `-CINV-000042`, `CINV-000042 `, `--help`,
  `../../etc/passwd`, and empty; `evidence_path` is built only from a
  compiled-in root plus the validated `CINV` and cannot be influenced by any
  argument; the launch-authorisation record schema is the **minimum** of §6 and
  a test asserts the helper reads no A1–A5 semantics beyond it.
- **RED:** `AssertionError: 'CINV-0000042' was accepted`
- **GREEN:** `bash tests/test-capability-execution.sh`
- **Commit:** `feat(provisioning): add transition helper policy logic`
- **Note:** privileged behaviour is **not** implemented here. See gate G2.

### T11 — Transition helper: privileged skeleton

**Files:** `provisioning/execution/kyri-exec-transition.py` (transition path)
**Interfaces:** `establish_context() -> CallerContext`, `drop_privileges() -> None`

- Failing tests: refuses when not running with root privilege; refuses when the
  caller cannot be established; never reads caller identity from argv, payload,
  or `CINV` content; constructs the worker environment explicitly and preserves
  none of `PATH`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `PYTHONPATH`, or runtime
  overrides; sets `no_new_privs`; verifies the uid/gid transition took effect;
  **contains no Podman invocation** (asserted by source discovery).
- **RED:** `AssertionError: helper did not refuse without root privilege`
- **GREEN**, regression set.
- **Commit:** `feat(provisioning): add privileged transition and drop`
- **STOP — reviewer gate G2.**

### T12 — Unprivileged worker and create/verify/start

**Files:** `tools/capability/execution/{worker,lifecycle}.py`
**Interfaces:** `Worker.run(session) -> None`,
`create(profile) -> ContainerId`, `verify(container_id, fingerprint) -> None`,
`start(container_id) -> None`

- Failing tests: `podman run` appears nowhere (source discovery); name derived
  solely from `CINV`; pre-launch collision → `execution_container_name_collision`,
  unstable → `…_unstable`; the worker writes to no authority root (attempted
  write raises); start occurs **only** after a `start_now` message; exactly one
  start attempt; candidate adoption requires the complete fingerprint; zero
  candidates → `execution_state_lost`.
- **RED:** `AssertionError: worker started the container without authorisation`
- **GREEN:** `bash tests/test-capability-execution-lifecycle.sh`
- **Commit:** `feat(execution): add the unprivileged worker and start authority`

### T13 — Terminal classification and timeout

**Files:** `tools/capability/execution/lifecycle.py` (classification)
**Interfaces:** `classify(observed, started_proven: bool) -> Classification`

- Failing tests: `Created` + exit 0 → launch failure, never success; lifecycle
  evaluated before `ExitCode` in every branch; timeout at 30 s is permanent even
  when the workload exits during the 2 s grace; contradictory lifecycle →
  `execution_lifecycle_integrity_failure` after which `ExitCode` is not trusted;
  timestamps are audit metadata and never normalised.
- **RED:** `AssertionError: Created/exit-0 classified as completed`
- **GREEN**, regression set.
- **Commit:** `feat(execution): classify lifecycle before exit code`

### T14 — Result and output-tree collector

**Files:** `tools/capability/execution/collector.py`
**Interfaces:** `collect(out_fd: int) -> OutputTree`,
`read_result(tree) -> dict`

- Failing tests: symlink, FIFO, socket, device, hard-link anomaly, traversal,
  absolute path, and directory-rename escape each rejected; 32 files / 16 MiB /
  2 MiB per file enforced; the **complete** tree is validated before a result is
  accepted; a valid `result.json` inside a violating tree still fails the
  invocation; missing → `result_missing`; malformed → `result_invalid`; nothing
  is repaired or normalised; extends `tools/common/trusted_source.py` rather
  than reimplementing the walk.
- **RED:** `AssertionError: symlink in output tree was collected`
- **GREEN:** `bash tests/test-capability-execution-collector.sh`
- **Commit:** `feat(execution): add the descriptor-safe output collector`

### T15 — Quarantine

**Files:** `tools/capability/execution/quarantine.py`
**Interfaces:** `admit(root) -> QuarantineReservation`, `collect(reservation, out_fd)`,
`seal(reservation) -> None`

- Failing tests: reserve `16 MiB + max(1 GiB, 5%)` respected; each collection
  durably reserves 16 MiB held until the terminal record commits; usage never
  reduces the reservation incrementally; admission rechecks physical free space;
  execution identity has no write authority; crash before the manifest →
  `quarantine_collection_incomplete` with no resume, append, overwrite, or
  deletion; `retain-quarantine-incomplete` seals only within bounds, else
  `quarantine_incomplete_integrity_failure`; `retain-quarantine-residue`
  releases the logical reservation without a manifest; quarantined evidence can
  never become a result.
- **RED:** `AssertionError: quarantine admitted below the physical reserve`
- **GREEN**, regression set.
- **Commit:** `feat(execution): add bounded forensic quarantine`

### T16 — Cleanup and recovery

**Files:** `tools/capability/execution/cleanup.py`
**Interfaces:** `cleanup(cinv) -> None`, `recover(root) -> list[Finding]`

- Failing tests: descriptor-safe, no-follow, internally derived roots only, no
  caller path accepted; no privileged recursive deletion fallback exists;
  cleanup runs only after evidence is durable; failure →
  `execution_cleanup_incomplete` with the slot still held; recovery is
  **admin-mediated** and performs no automatic retry; each §18 row produces its
  specified classification; cached observations never become authority.
- **RED:** `AssertionError: cleanup ran before evidence was durable`
- **GREEN**, regression set.
- **Commit:** `feat(execution): add cleanup and admin-mediated recovery`

### T17 — Administrative reconciliation and CADM

**Files:** `tools/capability/execution/admin.py`,
`provisioning/execution/kyri-exec-admin.py`,
`tests/test-capability-execution-admin.sh`
**Interfaces:** `allocate_cadm(root) -> str`,
`record_intent(cadm, verb, target) -> None`, `record_outcome(cadm, result) -> None`,
`inspect_admin_integrity(root) -> Summary`

- Failing tests: only the §20 verb set exists; no shell, no arbitrary path, no
  arbitrary container ID, no Podman passthrough, no environment override; CADM
  is monotonic from a **provisioned** counter with no runtime bootstrap,
  rollback detected, exhaustion fails closed; intent → one attempt → outcome,
  and a crash between yields `intent-with-unknown-outcome` with **no** replay;
  `intent` and `outcome` are create-once; `reconciliations` sequence is derived
  from immutable records with no mutable counter; namespace corruption →
  `administrative_record_integrity_failure`; unexpected object →
  `administrative_record_unexpected_object`; inspection is read-only, allocates
  no CADM, bounded to 2 MiB and 10,000 entries counting every entry, with
  truncation and scan-overflow classifications that block mutation; the audit
  event commits **before** the summary, else `inspection_audit_commit_failed`
  and the summary is withheld; destruction targets only an immutable ID already
  bound to the condition and never a replacement.
- **RED:** `AssertionError: destroy accepted a container name`
- **GREEN:** `bash tests/test-capability-execution-admin.sh`
- **Commit:** `feat(execution): add administrative reconciliation and CADM`
- **STOP — reviewer gate G3.**

### T18 — Adapter and CLI wiring

**Files:** `tools/capability/execution/adapter.py`, `tools/capability/cli.py`,
`tools/capability/coordinator.py`, `tools/capability/errors.py`
**Interfaces:** `PythonPodmanAdapter.execute(binding) -> AdapterOutcome`

- Failing tests: `invoke` no longer returns `no_authorised_adapter` when a
  governed implementation is available, and **still refuses** when it is not;
  the adapter satisfies the design §9 contract exactly and decides nothing; it
  cannot reach Fabric, Trust, or Health (asserted by discovery); the invocation
  record is durable before execution; the updated backstop in
  `tests/test-capability-runtime.sh` proves this adapter is the **only**
  execution path in the production package.
- **RED:** `AssertionError: invoke returned no_authorised_adapter with an available implementation`
- **GREEN**, full regression set.
- **Commit:** `feat(execution): wire the first adapter into the runtime`

### T19 — Production image definition

**Files:** `provisioning/image/Containerfile`, `provisioning/image/README.md`
**Interfaces:** none (provisioning artefact)

- Failing tests (static, no build): the definition contains no pip, package
  manager, compiler, sudo, SSH, curl, wget, or shell; declares a fixed non-root
  UID/GID; pins an exact Python patch version; **contains no reference to the
  Track-B Alpine digest**; the README documents digest capture and CIMP
  admission as an operator procedure, not an automated step.
- **RED:** `AssertionError: Containerfile references a package manager`
- **GREEN**, regression set.
- **Commit:** `feat(provisioning): define the production Python execution image`
- **STOP — reviewer gate G4.** The image is **not** built or admitted here.

### T20 — Integration tests against the real sandbox

**Files:** `tests/test-capability-execution-integration.sh`
**Interfaces:** none

- Tests: full path exercised against the **admitted** image; observed Podman
  profile verified field by field against §17; result collected and validated;
  a capability writing a symlink into the output tree fails the invocation; a
  capability exceeding memory is OOM-killed; a capability exceeding the PID
  limit is bounded; a capability attempting network access fails.
- **RED:** integration suite absent.
- **GREEN:** `bash tests/test-capability-execution-integration.sh`
- **Commit:** `test(execution): verify the adapter against the real sandbox`
- **Requires gates G4, G5, G6.**

### T21 — Failure injection and concurrency

**Files:** `tests/test-capability-execution-failure-injection.sh`
**Interfaces:** none

- Tests: crash injected at each §24 boundary yields the specified
  classification; two quarantines halt new execution
  (`execution_capacity_exhausted`); lock-order inversion is impossible; CMUT
  intent-without-outcome is never replayed; timeout during grace never becomes
  success; container-name collision paths both classify correctly.
- **RED:** injection suite absent.
- **GREEN**, full regression set.
- **Commit:** `test(execution): inject crashes at every durability boundary`

### T22 — Security backstops and closure

**Files:** `tests/test-capability-runtime.sh`, `tools/dev/run-validation.sh`,
`docs/history/v1.0-engineering-ledger.md`
**Interfaces:** none

- Tests: package-wide discovery proves no execution authority beyond this
  adapter; no module reaches Fabric, Trust, or Health from the execution path;
  no `podman run`, no socket, no API anywhere; new suites registered in the
  validator; ledger records the adapter as implemented and ENG-0005 as **still
  not complete**.
- **GREEN:** `tools/dev/run-validation.sh`
- **Commit:** `docs(capability): record first adapter implementation`
- **STOP — reviewer gate G7.**

## 5. Reviewer gates — hard stops

| Gate | Before | Blocks |
|---|---|---|
| **G1** | any sudoers change | after T10, before any policy is installed |
| **G2** | installing either helper to a root-owned path | T11 |
| **G3** | any setuid or file-capability decision | T17 — the accepted design uses **neither**; introducing one is a re-ruling |
| **G4** | host runtime-directory provisioning (`capability-handoff`, `execution`, `quarantine`, backing-store config, CADM counter) | T19 |
| **G5** | production image build and CIMP admission | T19 |
| **G6** | the first real privileged transition, and the first real Podman execution through Kyri | T20 |
| **G7** | cleanup of retained Track-B evidence, and any merge, tag, or release | T22 |

Tests **never** edit sudoers, install a helper, provision a runtime directory,
build or admit an image, or perform a privileged transition. Any task that
appears to require one has hit a gate.

## 6. Sequencing rules

TDD throughout: production code never leads its test. Privileged components
come **only** after their pure validation and policy logic is isolated and
tested unprivileged — which is why T10 precedes T11 and why T10's tests run
with no privilege at all. Host provisioning is a separate explicit gate, never
a task side effect. No ENG-0006, no subject seeding, no TrustGateway cutover.

## 7. Stop conditions

Halt and request a ruling if: the transition helper would need broad A1–A5
semantics; CMUT recovery appears to require design here; a second value would
need to cross the privileged boundary; the profile would need any caller
influence; Podman cannot express a control the profile requires; the
authority-set cannot satisfy both the 10,000-entry and 2 MiB bounds; a setuid
bit or file capability seems necessary; or any two accepted decisions conflict.

## 8. Acceptance

The specification's §36 criteria are the acceptance criteria. Every one maps to
a task: 1–3 → T10/T11 · 4 → T12 · 5 → T8/T20 · 6 → T2/T3 · 7 → T14 ·
8–9 → T13 · 10 → T6 · 11 → T6 · 12 → T5 · 13 → T21 · 14–15 → T22.

## 9. Related records

- [First adapter design](../specs/2026-08-11-first-adapter-design.md)
- [Execution transition boundary](../specs/2026-08-11-execution-transition-boundary.md)
- [Capability Runtime design](../specs/2026-08-10-capability-runtime-design.md)
- [Rootless execution prerequisite](2026-08-10-rootless-execution-prerequisite.md)
