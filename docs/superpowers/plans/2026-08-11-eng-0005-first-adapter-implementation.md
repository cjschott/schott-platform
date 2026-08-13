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
- Output tree: 32 regular files, 16 MiB aggregate, 2 MiB per file, maximum
  depth 16, maximum 256 total entries of every type, stdout and stderr 2 MiB
  each with independent `truncated=true`. Collector is descriptor-relative and
  no-follow, regular files only, rejecting symlinks, hard-link anomalies,
  FIFOs, sockets, devices, traversal, absolute paths, and directory-rename
  escape. Structural refusals are `output_tree_policy_violation`. **Any
  output-policy violation fails the invocation; a valid result never overrides
  it.**
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
- Container Python environment is adapter-owned and fixed: `PYTHONHASHSEED=0`,
  `PYTHONUTF8=1`, `LC_ALL=C.UTF-8`, `PYTHONDONTWRITEBYTECODE=1`, passed as
  `--env` and inherited from nothing. The last is load-bearing: `/kyri/package`
  is read-only.
- Per-`CINV` output containment: XFS project quota on `out/` only, project ID
  `1_000_000 + CINV`, 32 MiB and 512 inodes, limits provisioned as filesystem
  defaults and the runtime privilege reduced to one `FS_IOC_FSSETXATTR` ioctl.
  **No `xfs_quota`, `quotactl`, `ctypes`, or subprocess in the runtime path.**
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

**Files:** `provisioning/execution/kyri-exec-transition-action.py`

> **File split 2026-08-12, before implementation.** T11 was planned to add the
> transition path to the T10 policy file. It cannot: the T10 policy-only
> backstop scans that file and forbids every privilege syscall, `execve`, and
> `ctypes`, and the T11 ruling requires that backstop to remain **unchanged**.
> The privileged action therefore lives in its own module with its own narrowly
> scoped backstop, and the policy module keeps its guard intact. Packaging the
> two into one installed helper is a G2 concern, not a source-layout one.
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
**Interfaces:**
`verify_handoff(cinv: str, *, root_fd: int) -> HandoffSources`,
`create_argv(profile: ExecutionProfile, sources: HandoffSources) -> tuple[str, ...]`,
`create(backend, argv) -> str`, `observe(backend, container_id) -> ObservedProfile`,
`start(backend, container_id) -> None`,
`observe_lifecycle(backend, container_id) -> LifecycleObservation`,
`Worker.run(session, *, backend, root_fd) -> None`

> **Interfaces settled 2026-08-12, before implementation.** The originals named
> no backend, no handoff, and no root, so there was nowhere for the injected
> Podman seam or the verified handoff to enter. Handoff verification takes an
> already-open root descriptor and is descriptor-relative from there; the
> bind-source *strings* come from the compiled-in root plus the validated
> `CINV`, because Podman's bind interface consumes a pathname and
> `/proc/self/fd/N` is rejected as an unvalidated platform dependency.
> `HandoffBinding` stays path-free — descriptor continuity cannot cross the
> transition, since only descriptors 0, 1 and 2 survive it.
>
> **Subprocess binding is not assigned to T12.** The plan gives it no
> subprocess step, so the backend stays abstract and the T12 backstop forbids
> subprocess outright. Binding `/usr/bin/podman` to a real process is a later
> increment behind G6.

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

**Files:** `tools/capability/execution/collector.py`,
`tools/common/trusted_source.py` (additive, read-only)
**Interfaces:** `collect(out_fd: int) -> OutputTree`,
`read_result(tree: OutputTree, terminal: TerminalClassification) -> TrustedResult`

> **Files corrected 2026-08-12, before implementation.** The failing-test list
> below already requires T14 to extend `tools/common/trusted_source.py` rather
> than reimplement the walk, but the Files line named only `collector.py`, so
> the released Track-A module would have been modified without appearing in the
> plan's own file map. The extension is **additive and read-only**: an existing
> exported signature changes in no way, no existing caller widens, and the
> module's no-write backstop in `tests/test-capability-runtime.sh` stands
> unchanged. Execution-specific meaning — the 32-file and 16 MiB policy,
> `result.json`, trust, and classification — stays in `collector.py`; the common
> module receives only generic descriptor-relative traversal mechanics with
> caller-supplied bounds.
>
> **Interfaces settled 2026-08-12, before implementation.** `read_result`
> originally took the tree alone and returned a bare `dict`. Two properties the
> design requires were unexpressible in that shape. First, T13's
> `may_collect_result` is the gate for authoritative collection, so the terminal
> classification is an argument rather than something a caller may forget to
> consult. Second, §11 makes a valid result from a failed execution *untrusted
> diagnostic material*, and a `dict` carries no such distinction — a boolean
> beside it is a flag downstream code can ignore by accident. So `collect`
> returns an `OutputTree` that is structurally untrusted whatever it contains,
> and only `read_result` — refusing unless the classification permits it — can
> produce the distinct `TrustedResult` type. Nothing in the result bytes selects
> a path, alters a bound, or reaches the classification.

> **Traversal bounds ruled 2026-08-12, before implementation.** T14 stopped
> here: the accepted spec bounded the output tree by **regular files** only, so
> a tree with zero regular files could satisfy every byte and file limit while
> presenting unbounded depth or unbounded breadth, and traversal would exhaust
> descriptors, stack, or time before any file bound was consulted. The
> neighbouring ceilings were not transferable — §8's 1,024 entries bounds the
> package, §20's 10,000 bounds administrative scanning — so the value was left
> unfixed rather than chosen during implementation.
>
> The reviewer ruled **both** bounds, the two exhaustion shapes being
> independent: `OUTPUT_TREE_MAX_DEPTH = 16` and
> `OUTPUT_TREE_MAX_ENTRIES = 256`, now recorded in design §11. Depth 0 is the
> root, an entry directly beneath it is depth 1, and every enumerated entry
> counts toward 256 whatever its type, enumeration stopping at entry 257. The
> regular-file bounds are unchanged and independent.
>
> One classification is added to the closed §25 vocabulary,
> `output_tree_policy_violation`, taking it from 32 members to 33. It carries
> every **structural** refusal. `result_missing` and `result_invalid` keep their
> narrower meanings — tree valid but the canonical result absent, and result
> present but failing its document contract — so that a hostile filesystem shape
> is never reported as a malformed document. T1's vocabulary test takes the
> corresponding narrow update before T14 is implemented.

- Failing tests: symlink, FIFO, socket, device, hard-link anomaly, traversal,
  absolute path, and directory-rename escape each rejected; 32 files / 16 MiB /
  2 MiB per file enforced; depth 16 and 256 total entries enforced, with a tree
  carrying **no** regular file still refused on depth or entry count alone;
  every structural refusal → `output_tree_policy_violation`; the **complete**
  tree is validated before a result is accepted; a valid `result.json` inside a
  violating tree still fails the invocation; missing → `result_missing`;
  malformed → `result_invalid`; nothing is repaired or normalised; extends
  `tools/common/trusted_source.py` rather than reimplementing the walk.
- **RED:** `AssertionError: symlink in output tree was collected`
- **GREEN:** `bash tests/test-capability-execution-collector.sh`
- **Commit:** `feat(execution): add the descriptor-safe output collector`

### T15 — Quarantine

**Files:** `tools/capability/execution/quarantine.py`,
`tools/capability/execution/state.py` (additive lock kind),
`tools/capability/execution/mutation.py` (additive target kinds),
`tests/test-capability-execution-quarantine.sh`
**Interfaces:** `admit(root, cinv) -> QuarantineReservation`,
`collect(root, reservation, out_fd) -> QuarantineManifest`,
`seal(root, reservation, manifest) -> None`,
`seal_incomplete(root, reservation) -> QuarantineManifest`,
`retain_residue(root, reservation) -> None`

> **Structural bounds ruled 2026-08-12, before implementation.** T15 reuses
> T14's hostile-tree geometry rather than inventing a quarantine-specific one:
> depth 16, 256 total entries, 32 regular files, 2 MiB per file, 16 MiB
> aggregate, through `tools/common/trusted_source.walk_tree`. During
> `retain-quarantine-incomplete` sealing, any depth, entry, size, type, or link
> violation maps to the already-accepted
> `quarantine_incomplete_integrity_failure`; no new classification is added.
> The bounds are imported from `collector.py` rather than restated, so the two
> paths cannot drift apart into two contracts.
>
> **Interfaces settled 2026-08-12, before implementation.** The originals named
> no root and no `CINV`, so a reservation had nothing to be *for* and no
> verified authority root to be written through; every other execution module
> takes the `RootDescriptor` the backing store verified, and quarantine writes,
> so it needs one more than most. The two administrative dispositions the
> failing-test list already requires — `retain-quarantine-incomplete` and
> `retain-quarantine-residue` — are named as operations here; T17 binds the
> verbs to them and owns the `CADM` record.
>
> **Lock order, refused rather than chosen.** §23 lists a quarantine-capacity
> lock but fixes an order only for global capacity → per-`CINV`. Rather than
> invent a position for the third kind, `admit` takes the quarantine lock only
> when no other lock is held and refuses otherwise, so T15 adds no ordering to
> the specification and the ambiguous nesting fails closed. If a later increment
> genuinely needs to nest them, the order is a reviewer question at that point.

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

**Files:** `tools/capability/execution/cleanup.py`,
`tests/test-capability-execution-cleanup.sh`
**Interfaces:** `cleanup(root, handoff, cinv) -> None`,
`recover(root) -> list[Finding]`

> **Interfaces corrected 2026-08-12, before implementation.** `cleanup(cinv)`
> held no root at all, so the tree it removes would have been derived from a
> pathname — the one thing §19 forbids. Under the standing descriptor rule it
> takes the verified authority root, whose durable state says whether cleanup
> may run, and the verified handoff parent, beneath which the per-`CINV`
> subtree is derived internally. No caller path reaches either.
>
> **Cleanup-owned objects, settled 2026-08-12.** §19 says "internally derived
> per-`CINV` roots" without enumerating them; §13 does enumerate every per-`CINV`
> object, so the set is derived rather than chosen: the handoff subtree
> `/data/kyri/capability-handoff/<CINV>/` and what §14 puts inside it —
> `package/`, `payload`, and `out/`. Nothing else is per-`CINV` and removable.
> Quarantine is excluded by §15, which gives v1 no deletion path at all, and
> execution state under `…/execution/` is the durable authority cleanup depends
> on. Cleanup is `collected` → `cleaned`; capacity release stays T7's.
>
> **Missing, malformed, substituted, symlinked, or ambiguous is
> `execution_cleanup_incomplete`** with the slot held, per the reviewer's T16
> ruling. Note for the record: because cleanup removes only what it enumerates,
> a partially cleaned tree still presents a root, so `retry-cleanup` re-runs
> normally. The one case a missing root can arise is a crash between removing
> the root and committing `cleaned`, which fails closed to `retain-residue` —
> the non-destructive escape hatch §19 already provides.

> **Deletion-work bounds ruled 2026-08-12, before implementation.** T16 stopped
> here: cleanup had no traversal bound, and `out/` is the one place an adversary
> controls the shape without limit, since §11 governs what collection accepts
> rather than what the workload may write and §12 sets no disk quota.
>
> The reviewer ruled `CLEANUP_MAX_DEPTH = 32` and `CLEANUP_MAX_ENTRIES = 8192`
> over the whole per-`CINV` handoff subtree, deliberately larger than the
> acceptance limits because cleanup exists to face residue that has already
> broken them. Violation is `execution_cleanup_incomplete` with the slot held,
> no broadening, no automatic retry, and `retain-residue` as the operator's
> move. Recorded in design §19.
>
> **The destructive walker lives in `cleanup.py`, not in `trusted_source.py`.**
> Deletion is deliberately not a trusted-source responsibility: that module is
> read-only and its no-write backstop is worth more than the reuse would be
> worth. `walk_tree` is also the wrong shape, since it returns file bytes for
> evidence and removal needs none. The cleanup walker is descriptor-relative,
> streaming, post-order, and buffers no more of the namespace than the entry
> budget already allows.
>
> **Non-directory objects are unlinked, not refused.** The T16 brief listed
> "symlinked" among the ambiguous states, and the walker ruling asked for "no
> traversal through symlinks"; the two readings differ, and this takes the
> second. `os.unlink` on a descriptor-relative name removes the link and never
> the target, so it is not the broader deletion the first reading guards
> against — while refusing instead would let one symlink in `out/`, the most
> ordinary hostile artefact there is, permanently consume one of two slots.
> Directories are the only kind ever opened, and only after their identity is
> confirmed on the descriptor.
>
> **The per-`CINV` output quota gap is out of scope here** and recorded in
> design §34 as a G4/G5 hardening item. ENG-0005 introduces no `xfs_quota`, no
> project ID, no mount-option assumption, and no storage override.

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
`record_intent(root, cadm, verb, cinv, target) -> None`,
`record_outcome(root, cadm, result) -> None`,
`record_reconciliation(root, cadm, note) -> str`,
`unknown_outcomes(root) -> tuple[str, ...]`,
`read_binding(root, cinv) -> BoundTarget | None`,
`perform(context, authorisation, cinv) -> AdminOutcome`,
`inspect_admin_integrity(root, *, audit) -> Summary`

> **Interfaces settled 2026-08-12, before implementation.** The originals took
> no root on three of four calls, so a record would have been written through a
> pathname; under the standing rule every one takes the verified
> `RootDescriptor`. `perform` is the verb dispatcher the plan's failing tests
> require but never named, and it takes an `AdminContext` bundling the verified
> execution, handoff, and quarantine roots plus the injected destruction
> backend, so no verb can reach a root it was not given. `record_reconciliation`
> and `unknown_outcomes` are likewise named for behaviour the failing tests
> already demand.
>
> **The destruction binding is read, not accepted.** §20 permits destroying only
> an immutable object "already durably bound to the relevant condition", which
> is unverifiable if the caller hands the identity in — so `read_binding`
> reads it from the create-once `state/<CINV>` record that
> `TargetKind.EXECUTION_STATE` already reserves and nothing yet writes. §17
> assigns that write to whoever persists the container ID after creation, which
> is the coordinator in T18. Until then every destroying verb refuses for want
> of a binding, which is the fail-closed direction and exactly what the absent
> record should mean. T17 settles the read contract — `cinv`, `schema_version`,
> `container_id`, `condition` — and T18 must satisfy it.
>
> **Authentication is modelled, not performed.** `Authorisation` is the value
> the interactive-authenticated helper presents, naming the operator and the one
> verb it was granted for. T17 implements the policy and dispatch; the helper
> source is written but never installed, no sudoers is touched, and no test
> authenticates. Gates G2 and G3 stay closed.

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

**Files:** `tools/capability/execution/adapter.py`,
`tools/capability/coordinator.py`,
`tests/test-capability-execution-adapter.sh`
**Interfaces:** `PythonPodmanAdapter.execute(binding) -> AdapterOutcome`

> **Files corrected 2026-08-12, before implementation.** `cli.py` and
> `errors.py` are listed but need no change: the CLI must reach no adapter
> while G4–G6 are closed, so leaving it untouched is the behaviour rather than
> an omission, and the adapter's refusals are execution-domain types beside
> every other increment's. The adapter's own suite is added for the same reason
> T14–T17 each have one — the execution modules are tested in
> `tests/test-capability-execution-*.sh`, not in the Track-A suite.
>
> **The coordinator seam takes both an adapter and a binding.** Execution needs
> an authorised mechanism *and* something governed for it to run; an adapter
> with nothing bound to it has nothing to execute, and the coordinator cannot
> assemble a binding without the provisioned runtime G4 gates. Either absent is
> `no_authorised_adapter`, unchanged.

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

> **Base image ruled 2026-08-12, before implementation.** T19 stopped here: no
> base satisfied both T12's fixed `/usr/bin/python3` and §27's ban on a package
> manager, compiler, or shell. The slim official variants carry no
> `/usr/bin/python3` at all, the full ones resolve it to a different interpreter
> from the pinned one, distroless floats its patch version, and building from a
> distro base puts a package manager into the definition.
>
> The reviewer ruled the interpreter path adapts to the image rather than the
> reverse: `CONTAINER_INTERPRETER` becomes **`/usr/bin/python`**, an authorised
> correction to a released module, with the host `WORKER_INTERPRETER`
> untouched. The base family is the minimal Chainguard Python runtime, supplied
> as a digest-pinned `BASE_IMAGE` argument with **no default**; governed Python
> is **3.14.6**, proven three independent ways at admission; and
> `/usr/bin/python` **may** be a symlink because the OCI digest commits the link
> and its target together, with resolution and an interpreter digest recorded as
> provisioning evidence. Recorded in design §27.
>
> The forbidden-tooling rule is also clarified there: it governs the **final
> runtime image**, not whether the definition may mention a build stage. The
> earlier reading was stronger than intended. This image needs no build stage
> regardless.
>
> **Files corrected.** `tests/test-capability-execution-image.sh` is added, for
> the same reason every increment since T14 has its own suite. T12's
> `worker.py` and `tests/test-capability-execution-lifecycle.sh` change with the
> interpreter correction.
>
> The per-`CINV` output byte and inode quota (design §34) stays unresolved and
> is a G4/G5 host-storage item. The image does not address it.

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
| **G4** | host runtime-directory provisioning (`capability-handoff`, `execution`, `quarantine`, backing-store config, CADM counter) | T19 — **CLOSED 2026-08-12**, see below |
| **G5** | production image build and CIMP admission | T19 |
| **G6** | the first real privileged transition, and the first real Podman execution through Kyri | T20 |
| **G7** | cleanup of retained Track-B evidence, and any merge, tag, or release | T22 |

Tests **never** edit sudoers, install a helper, provision a runtime directory,
build or admit an image, or perform a privileged transition. Any task that
appears to require one has hit a gate.

### G4 — executed and accepted, 2026-08-12

Host provisioning was performed on `schai` from source checkpoint `34c18a7`
against [the G4 runbook](../../../provisioning/execution/README.md), which
carries the full evidence record. In summary: `/data` mounts `prjquota` with
project quota accounting and enforcement ON; `/etc/kyri/backing-store.json` is
installed `root:root` `0444` from independently observed facts and verified
through the normal `verify_backing_store` path from both the repository source
and the installed authority; default project limits are 32 MiB / 512 inodes;
byte and inode enforcement were **proven by actual filesystem refusal** on
disposable project `999000`, which was then fully cleaned up; the runtime roots
carry the §13 ownership and modes; and `/usr/lib/kyri/python` plus the three
`/usr/libexec` helpers are installed `root:root` and read-only, resolving
nowhere through `/opt/schott-platform`.

**Provisioning is not execution.** No helper was invoked. **G1, G3, G5, G6, and
G7 remain closed** — no sudoers policy exists, no production image was built or
admitted, and the transition and worker were never run.

The `kyri-capability` rootless Podman store still holds Track-B test artefacts
that predate G4 by roughly 29–30 hours. They are **not** evidence that G5 or G6
opened: physical emptiness of the historical rootless store is not a G5 or G6
requirement. Their removal is G7 work and stays deferred.

Validation after provisioning surfaced two defects, **both since corrected in
source** by the reviewed correction between G4 and G5 (see below). Two
follow-ups remain recorded in the runbook and deliberately unactioned: the
installed dependency closure is wider than the real import closure, and
source/installed drift must only ever be resolved by an explicit reviewed
re-provisioning event.

### G4→G5 correction — namespace-package import gap, 2026-08-12

`tools` shipped without an `__init__.py`, so the installed
`/usr/lib/kyri/python/tools` was a **namespace** package. A namespace portion
does not terminate the import search, so a *regular* `tools` package found
later on `sys.path` won outright — despite both entrypoints inserting the
canonical root at position 0. Measured twice: a decoy on `PYTHONPATH` had its
module-level code execute before the post-import `realpath` check refused, and,
more seriously, with the checkout on `sys.path` at all `tools.__path__`
resolved to `/opt/schott-platform/tools` — the coordinator-writable tree the
authority split exists to exclude.

Corrected by adding an intentionally empty `tools/__init__.py` to source and to
the §8.2 install matrix. Both existing checks are unchanged; this closes the
window between them. Proven RED then GREEN by import-boundary tests that build
a canonical root from the matrix in a temporary directory, so the property is
now exercised on every host — previously it was only ever exercised on a
provisioned one, and passed vacuously in CI.

Five suites that proved non-provisioning by asserting production paths are
*absent* were reworked to snapshot and compare path metadata instead, so they
are valid on a clean host and a G4-provisioned host alike. Gate state
(`/etc/sudoers.d/kyri-exec`, `/run/kyri`) keeps its absolute absence assertion.

**Source is green: 41/41 suites and the full validator at 57/57.** The
installed tree still carries the pre-correction generation until the operator
performs the explicit re-provisioning; G4 is not reopened and no gate changes.

### G5 implementation pass 1 — immutable image identity, 2026-08-12

`oci_digest` became **`oci_image_id`** across every ENG-0005 execution-authority
surface, with syntax `^[0-9a-f]{64}$` and no `sha256:` prefix. Authority is the
local image ID (`podman image inspect .Id`); the post-create readback is
`podman container inspect .Image`. Manifest digests, `.ImageDigest`,
`.RepoDigests`, `.RepoTags`, `.ImageName`, tags, and repository names are all
non-authoritative, and the bare syntax makes each of them structurally
unrepresentable rather than merely discouraged. Ruled in design §5.

The observation path was corrected with it. `lifecycle.observe` read
`.ImageDigest` — a real Podman field, but one carrying a **registry manifest
digest**, so a container was verified against a value that depends on how the
image arrived and is absent for a locally built one. It now reads `.Image`.

Renamed in `types.py`, `implementation_authority.py`, `profile.py`,
`protocol.py`, `lifecycle.py`, `worker.py`, and
`provisioning/execution/kyri-exec-transition.py`, so the profile canonical form
and fingerprint, the `VERIFIED_PROFILE` message, and the bounded launch
authorisation record parsed by root all commit the same field. No compatibility
shim exists: no `CIMP` has ever been admitted, and a dual vocabulary in an
authority schema is migration debt with no beneficiary.

**REQUIRED BUT NOT YET IMPLEMENTED**, and deliberately not started in this
pass: the inert-future-CIMP reader tolerance, the offline
implementation-authority writer, the `/var/lib/kyri/implementation-authority`
namespace and its control root, the canonical provisioning-evidence manifest,
the governed adapter and argv identity constants, and the exported payload
schema-version constant. Documentation of those describes **required future
behaviour, not current runtime behaviour**.

**Generation 3 is now required.** Six installed library modules and one
installed internal module differ from source; the three `/usr/libexec`
entrypoints are byte-identical and unchanged. The host runs generation 2 until
a separately reviewed re-provisioning installs the delta recorded in the
runbook. No gate changes: G5 stays closed.

### G5 governance — interrupted admission resolved, 2026-08-12

The last open G5 decision is closed. A published-but-unlisted CIMP is **not** a
permanent steady state; it is an unresolved interrupted transaction requiring
explicit operator disposition. The earlier "permanently inert future CIMP"
ruling is withdrawn, because it contradicted its own fail-closed list: an
abandoned inert CIMP became an integrity finding the moment a later admission
raised the high-water mark past it.

The reader gains a third classification — VALID,
VALID_WITH_PENDING_DISPOSITION, INVALID — and the full model is recorded in
design §5.1–§5.7: high-water semantics, the `CIMP-000000` reservation, COMPLETE
and RETIRE ceremonies, orphan-generation handling, the staging boundary, the
normal transaction, the crash-point matrix, and the namespace and control
matrices. Three refinements were derived while validating it:

- **Superseded generations are not orphans.** Every ancestor of the current
  generation is non-current, so "non-current implies pending" would leave any
  namespace with history permanently pending. The distinction is the ancestry
  chain, and because the reader never enumerates `generations/`, orphan
  detection belongs to the offline writer rather than the runtime path.
- **All pending CIMPs must be dispositioned in one successor generation.**
  Doing them sequentially would raise the high-water mark past a still-pending
  lower ordinal — the INVALID condition — so the ceremony would transit through
  global freeze.
- **Retirement cannot record why.** The record is a closed `{"cimp": …}` schema
  and is not extended; the generation chain already distinguishes *never
  authorised* from *later withdrawn*, and immutable history is better evidence
  than a field that would have to be trusted.

**Test boundary — closed by Pass 2A.** The case *"an on-disk CIMP absent from
the manifest fails closed"* asserted the pre-ruling behaviour and was replaced
by the pending-disposition section when the tolerance was implemented, not when
it was documented.

### Pass 2A — reader classification, implemented

`current_generation()` still raises on INVALID and still returns a `Generation`
for both valid states, so no caller changed. The snapshot now carries `state`
and an ordered `pending` tuple of frozen `PendingImplementation` records, each
naming its `PendingDisposition`. Putting them on the snapshot rather than
behind a second query is deliberate: obtaining authority and learning about
unfinished transactions cannot come apart, so the writer cannot read one
without the other.

Tolerance covers the *omission* only. A future ordinal buys no leniency about
canonical bytes, schema, identity, unexpected objects, or symlinks; all of
those remain global findings, as does an unlisted ordinal at or below the
high-water mark, and `CIMP-000000` in either the namespace or an authority set.
`resolve_implementation` refuses a pending CIMP as `UnknownImplementation` and
says which disposition is outstanding, so an operator reads *awaiting
disposition* rather than *never existed*.

Two fixture defects surfaced while proving it. `build()` never created
`implementations/` for an empty genesis namespace, which a real provisioned
namespace always carries. And an unlisted CIMP whose ordinal *equals* the
high-water mark is unreachable by construction — the ordinal is the directory
name, so it cannot be both listed and unlisted; only *strictly below* can
occur, and the test now asserts that with a retired entry holding the ordinal.

#### G5 ruling status

| Ruling | Status |
|---|---|
| `oci_image_id` replaces execution-authority `oci_digest` | **IMPLEMENTED** (`affbc86`) |
| syntax `^[0-9a-f]{64}$`, `sha256:` prefix refused | **IMPLEMENTED** |
| Podman image `.Id` is the authority source | **IMPLEMENTED** (recorded contract) |
| Podman container `.Image` is the execution readback | **IMPLEMENTED** |
| tags, manifest digests, `.ImageDigest`, `.RepoDigests` non-authoritative | **IMPLEMENTED** |
| image presence ≠ authority · tag ≠ authority | **IMPLEMENTED** |
| worker chooses no image; no runtime pull or fetch | **IMPLEMENTED** |
| corruption remains globally fail-closed | **IMPLEMENTED** |
| `PROFILE_SCHEMA_VERSION = 1` | **IMPLEMENTED** |
| three-state reader model and pending disposition | **IMPLEMENTED** (Pass 2A) |
| `PENDING_ADMISSION` / `PENDING_RETIREMENT` subtypes | **IMPLEMENTED** (Pass 2A) |
| `CIMP-000000` reserved; semantic rejection | **IMPLEMENTED** (Pass 2A) |
| high-water rule, empty genesis set = 0 | **IMPLEMENTED** (Pass 2A) |
| independent persistent CIMP and CGEN counters | **IMPLEMENTED** (Pass 2B) |
| `CGEN-000000000000` genesis with empty authority set | **IMPLEMENTED** (Pass 2B) |
| normal allocation begins at `CIMP-000001` / `CGEN-000000000001` | **IMPLEMENTED** (Pass 2B) |
| permanent identifier gaps | **IMPLEMENTED** (Pass 2B) |
| `implementation-lifecycle` mutation lock | **IMPLEMENTED** (Pass 2B) |
| offline writer, COMPLETE and RETIRE ceremonies | REQUIRED, NOT YET IMPLEMENTED |
| ordinary admission transaction | REQUIRED, NOT YET IMPLEMENTED |
| orphan-generation reconciliation | REQUIRED, NOT YET IMPLEMENTED |
| authority and control namespaces on disk | REQUIRED, NOT YET IMPLEMENTED |
| canonical provisioning-evidence manifest, 15 fields | REQUIRED, NOT YET IMPLEMENTED |
| `provisioning_evidence_digest` = SHA-256 of canonical bytes | REQUIRED, NOT YET IMPLEMENTED |
| `python-podman-v1` · `fixed-python-entrypoint-v1` as constants | REQUIRED, NOT YET IMPLEMENTED |
| exported payload schema-version constant | REQUIRED, NOT YET IMPLEMENTED |
| coordinator resolves authority; root and worker do not | REQUIRED, NOT YET IMPLEMENTED |
| Track-B residue cannot grant production authority | holds structurally; no admission path exists yet |

### Pass 2B — offline bootstrap primitives, implemented

`tools/provisioning/authority_bootstrap.py` provides the CIMP and CGEN
counters, the `implementation-lifecycle` lock, and the genesis ceremony. It
lives **outside** the install matrix deliberately: the matrix covers
`tools/capability` and `tools/common`, so the writer never reaches the
root-owned runtime library, and the boundary is a property of what exists on
the host rather than a rule to remember. A suite check scans the worker,
lifecycle, adapter, reader, coordinator, and all four transition sources to
prove none of them imports it, and rejects absolute path literals in the module
so the production mapping stays with operator integration.

Counters follow the existing CADM precedent exactly — zero-padded ASCII digits
and a newline, incremented durably *before* the caller sees the value. That
ordering is what burns an identifier: a caller that dies holding one leaves a
permanent gap rather than a number that gets handed out twice. Both are
provisioned at zero, which is also what makes `CIMP-000000` and
`CGEN-000000000000` unreachable from the allocators — never emitted, not
emitted and then filtered. Genesis consumes neither, proven directly.

The lock is non-blocking. A ceremony that quietly waited on another would look
like a slow command and finish in an order nobody chose, so contention refuses
and says which mutation already holds it. Runtime readers take no lock, so
there is no ordering to establish against the coordinator's `capacity` and
`quarantine-capacity` locks.

Genesis stages, fsyncs, verifies the staged bytes by reading them back,
publishes by rename, installs the pointer by rename, and then asks the **Pass
2A reader** whether the result is valid — it does not re-implement authority
interpretation, so a genesis the runtime would reject cannot be reported as
successful. It refuses a second run, any pre-existing authority material, a
symlinked or wrong-typed object, missing or malformed control state, and
staging residue, which it never removes: discarding somebody else's unfinished
work is an explicit recovery action, not something a routine primitive does on
the way past.

Two boundary corrections came out of writing it. The suite's own scanner
initially banned `scandir` module-wide, which is wrong — genesis legitimately
enumerates to prove a directory is empty, a different question from "what
number comes next" — so the check is now scoped to the allocation path. And the
header tripped the production-path backstop by putting the word "touches" next
to `/var/lib/kyri`; it carries the repository's `prod-path-reference` marker
now, which is the sanctioned greppable exception.

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
