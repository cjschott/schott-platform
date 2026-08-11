# ENG-0005 First Adapter Design — Bounded Local Python Execution

**Status:** Proposed — not accepted

> **Specification only. This document authorises no implementation and no host
> change.** No helper, sudoers entry, unit, runtime directory, production
> image, or adapter code is created by it. Host prerequisites (§34) are
> described so an operator can review them, not applied.

Consolidates the accepted
[execution transition boundary](2026-08-11-execution-transition-boundary.md)
and the [Track-B enforcement
findings](../plans/2026-08-10-rootless-execution-prerequisite.md#22-track-b-provisioning-outcome-2026-08-11)
into the concrete first adapter for the
[Capability Runtime](2026-08-10-capability-runtime-design.md).

## 1. Purpose

Execute **one governed Python entrypoint** from a verified capability package,
inside a rootless Podman container with no network, no devices, no secrets, and
no shell, and return one bounded JSON result — or fail closed with a durable,
inspectable reason.

This is the adapter §9 of the Capability Runtime design left abstract and
§10.2 made conditional. It decides nothing: the Fabric selected, the
coordinator verified, and this adapter translates and executes.

## 2. Non-goals

Not a generic container execution API · not a shell adapter · not
network-enabled · not a device or GPU adapter · not multi-runtime · not an
arbitrary subprocess adapter · not an image-selection API · not a Podman
API or socket proxy. Network, persistent storage, devices, GPU, subprocess
authority, and secrets each require separate governance.

## 3. Authority model

```
Operator Root Authority (external, out of band)
  → governed image provisioning  → CIMP admission, CGEN generation
  → Fabric governance → CSEL
    → Capability Runtime preconditions (design §6)
      → coordinator (cschott): reserve, authorise, record
        → transition helper (root, one-shot)
          → worker (kyri-capability)
            → rootless Podman → container (uid mapped, unprivileged)
```

Three identities, and the split is the security property:

| Identity | Holds | Must never hold |
|---|---|---|
| `cschott` coordinator | Fabric evidence, Capability Runtime store, canonical staging, capacity and lifecycle authority, quarantine | Podman authority, host root |
| root (helper) | privilege to verify, prepare handoff, and drop | Podman, caller paths, arbitrary argv |
| `kyri-capability` worker | rootless Podman, handoff read, output leaf write | repository, canonical staging, Fabric, Trust, evidence write, capacity/lifecycle authority |

**The worker is not trusted to create execution authority.** Its authority is
bounded before it starts, by the transition component and the immutable
handoff.

### 3.1 Derived decision — one transition, coordinator as sole authority writer

The lifecycle requires durable `container_verified` and `start_authorized`
between `podman create` and `podman start`. Only `kyri-capability` can reach
rootless Podman; only `cschott` may write authority state. A second privileged
crossing to start the container would require passing a **container ID** across
the privileged boundary, which the accepted transition contract forbids — the
only input that crosses is `CINV-nnnnnn`.

Therefore: **exactly one transition per invocation**, and the coordinator and
worker exchange structured messages over descriptors the helper inherits and
passes through. The worker **observes and reports**; the coordinator
**validates and commits**. No authority state is written by uid 999.

Protocol: newline-delimited canonical JSON, one object per message, 64 KiB per
message maximum, closed grammar, unknown fields rejected. Worker→coordinator:
`created`, `verified_profile`, `started`, `terminal`, `collected`, `error`.
Coordinator→worker: `start_now`, `abort`. A malformed, oversized, out-of-order,
or unexpected message is `execution_protocol_violation` and aborts the
invocation. The coordinator never executes anything the worker sends; every
message is data validated against a closed schema.

## 4. Identities

| Identity | Grammar | Allocated by | Purpose |
|---|---|---|---|
| `CINV` | `^CINV-[0-9]{6}$` | Capability Runtime | invocation record; the only value crossing the privileged boundary |
| `CRES` | `^CRES-[0-9]{6}$` | Capability Runtime | result record |
| `CIMP` | `^CIMP-[0-9]{6}$` | offline governed provisioning | implementation admission decision |
| `CGEN` | `^CGEN-[0-9]{12}$` | offline governed provisioning | published authority generation |
| `CADM` | `^CADM-[0-9]{6}$` | coordinator | administrative attempt |
| `CMUT` | `^CMUT-[0-9]{12}$` | coordinator (foundational layer) | authority-bearing mutation |

All are monotonic, gaps permanent, never reused, exhaustion fails closed. None
is ever caller-supplied. The caller-supplied `invocation_id` remains opaque and
never parsed (design §4) and **never crosses a privilege boundary**.

## 5. CIMP / CGEN provisioning interface (consumed, never written)

The adapter is a **read-only consumer**. It never allocates a `CIMP` or `CGEN`,
never writes provisioning state, and has no repair authority.

**CIMP admission** is create-once immutable and binds: `CIMP`; exact OCI
digest; adapter/mapping version; payload schema version; execution-profile
schema version; fixed executable/argv contract identity; provisioning evidence
commitments. **Retirement** is a separate create-once immutable record and is
permanent — no reactivation, no mutation. Any change to digest, image build,
executable mapping, schema, or profile requires a **new CIMP**.

`CIMP` identifies the *governance decision*; the OCI digest identifies the
*immutable bytes*. One governed implementation version maps to exactly one
digest.

**Retirement vs removal are separate decisions.** Retirement answers *may new
`CINV` bind this `CIMP`?* and becomes authoritative immediately once its record
reaches full durability. Image removal answers *may these local bytes be
garbage-collected?* and requires: `CIMP` already retired; zero unresolved
`CINV` references to that exact `CIMP`/digest; and the shared
implementation-lifecycle serialisation preventing new references during
retirement and removal. Retirement is permitted even when admission capacity is
exhausted, provided the resulting complete authority manifest still fits the
bounds below.

**Authority namespace.** Fabric derives implementation eligibility from
canonical provisioning records only. There is **no independent mutable Fabric
implementation registry**. Malformed, duplicate, identity-mismatched,
unexpected-object, or otherwise unverifiable canonical CIMP state produces
`implementation_authority_integrity_failure`: all new CIMP authorisation
freezes globally, already-bound `CINV` authority remains valid, and there is no
runtime repair authority.

**Inspection bounds in the authorisation path** — maximum 10,000 directory
entries, maximum 2 MiB canonical integrity summary, every encountered entry
counts, no pagination and no filtering. Scan overflow is
`implementation_authority_scan_limit_exceeded`; summary overflow is
`implementation_authority_findings_truncated`. Both imply global implementation
authority integrity failure.

**Generations.** Provisioning publishes immutable generations. Genesis is
`CGEN-000000000000`; normal allocation begins at `CGEN-000000000001`. Each
generation publishes an `authority-set` and a `generation` record.

The authority-set manifest is the **complete** CIMP authority set, sorted
numerically by CIMP, canonically serialised, each entry carrying `CIMP`, the
SHA-256 of the exact admission record, and the SHA-256 of the exact retirement
record or `null`. Active and retired entries are both included. Maximum 10,000
entries and 2 MiB canonical bytes, **no truncation**.

The generation record binds `CGEN`, predecessor `CGEN`, predecessor generation
SHA-256, and authority-set SHA-256. Only genesis may carry null predecessor
fields. `current-generation` names the exact `CGEN` and generation-record
SHA-256.

Publication order: validate canonical CIMP state → construct canonical
authority-set → durably commit authority-set → compute and verify digest →
durably commit generation → durably advance `current-generation`.

Fabric may hold an in-memory validated eligibility snapshot **only** while its
`CGEN` and digest exactly match canonical `current-generation`; any mismatch
invalidates the entire snapshot.

**Capacity, computed.** A canonical entry
`{"cimp":"CIMP-000001","admission":"<64 hex>","retirement":null}` is 119 bytes;
with a retirement digest it is 181 bytes; with the separator, 182. Ten thousand
maximal entries plus envelope is ≈ 1.82 MiB against the 2 MiB (2,097,152 byte)
bound — roughly 277 KiB of headroom. **Both bounds are therefore satisfiable
simultaneously**, and the byte bound binds first only if the schema grows an
entry beyond ~209 bytes. If the complete history cannot fit,
`implementation_authority_capacity_exhausted`: no pruning, no compaction, no
renumbering, no omission of retired history, no automatic second namespace, no
automatic schema expansion. Expansion requires an explicit provisioning schema
migration that preserves historical authority.

## 6. Transition helper contract

```
cschott → sudo <exact absolute helper path> CINV-nnnnnn
```

One argument, matching `^CINV-[0-9]{6}$`, constrained by the sudoers policy
**and independently revalidated by the helper**.

**Root does, in order:** establish it is executing in the expected authorised
transition context and that the caller is `cschott`, refusing if it cannot;
revalidate the `CINV` grammar totally; construct the evidence pathname itself
from a compiled-in root and the validated `CINV`, with **no caller-supplied
path component**; read the minimum immutable evidence required to confirm the
invocation exists, is `launch_authorized`, is not refused, not conflicting, and
not already attempted; verify the handoff exists with expected ownership and
modes and establish the ownership root cannot; `setgroups([987])`,
`setgid(987)`, `setuid(999)`, verify the transition took effect; set
`no_new_privs`; `execve` the worker with an explicitly constructed environment.

**Root MUST NOT:** run Podman; construct container argv from caller input;
accept a caller-supplied path, image, mount, environment, or runtime/resource
flag; expose a shell or a generic user-switch; implement selection; call Trust
or Health; mutate Fabric; or become a general Capability Runtime API.

**Schema stop condition.** If the helper would need broad A1–A5 semantics to
determine `launch_authorized`, that is a **halt-and-rule event**, not a design
problem to solve by growing the helper. The mitigation is a single
coordinator-written, create-once **launch authorisation record** whose schema
the helper reads: `CINV`, `CIMP`, OCI digest, handoff root, profile schema
version, and the coordinator's commitment digest. The helper understands that
one record and nothing else.

Environment: absolute paths only for every security-sensitive executable and
configuration reference; no reliance on `PATH` or `secure_path`; `PATH`,
`LD_PRELOAD`, `LD_LIBRARY_PATH`, `PYTHONPATH`, executable/runtime override
variables, Podman configuration override variables, and arbitrary caller
environment are never preserved.

## 7. Unprivileged worker contract

Runs as `kyri-capability` with `no_new_privs` set, an explicitly constructed
environment, and inherited protocol descriptors.

**Owns:** fixed Podman argv construction from adapter-owned values; `podman
create`; container fingerprint observation; `podman start` on explicit
coordinator authorisation; lifecycle observation; timeout and termination;
bounded `stdout`/`stderr` capture; result and output-tree collection through the
descriptor-safe no-follow collector; classification input.

**Must not:** write any authority state; decide capacity; allocate any
identifier; read the repository, canonical staging, Fabric, or Trust; alter the
profile; choose an image; or self-attest a successful start.

## 8. Package contract

Python source and package-local data only. **No** native extensions, ELF
binaries, shared libraries, native-code wheels, package-provided interpreters,
or executable helper binaries.

Bounds: **64 MiB** aggregate, **1,024** entries, **16 MiB** per file.

Mounted read-only at `/kyri/package`. Exactly one governed relative `.py`
entrypoint strictly beneath it — no absolute path, no traversal, no symlink
escape, no discovery, no multiple entrypoints, no non-Python entrypoint.

The entrypoint may import the Python standard library and `.py` modules from
the same verified package. **No arbitrary `PYTHONPATH`.** Package-local data
files are readable, read-only.

## 9. Python execution contract

```
<fixed-absolute-python> /kyri/package/<verified-entrypoint>
```

No capability arguments. No caller-, payload-, or package-controlled argv
appended. No `python -c`, no `python -m`, no shell, no arbitrary executable.
**No subprocess execution contract in v1** — the capability executes
in-process. The 64-PID limit is defence in depth, not permission.

Adapter-owned Python environment: deterministic hash seed
(`PYTHONHASHSEED=0`), UTF-8 locale and encoding behaviour
(`PYTHONUTF8=1`, `LC_ALL=C.UTF-8`), bytecode writes disabled
(`PYTHONDONTWRITEBYTECODE=1`, which is also what makes a read-only package
mount viable), and no inherited caller `PYTHON*` configuration.

The real system clock is readable, but the **governed invocation instant is
authoritative** for governance-relevant timestamps. The kernel CSPRNG may be
available for ordinary computation; randomness can never manufacture Kyri
authority, identity, or governance state. A capability declares a minimum
Python compatibility; that declaration **cannot select** an interpreter, image,
or runtime.

## 10. Payload contract

Read-only mounted file at `/run/kyri/input/payload`. Never argv, never
environment, no stdin streaming authority.

Canonical UTF-8 JSON, exactly one document, top-level object, **duplicate keys
rejected at any nesting depth**, maximum **2 MiB** canonical bytes.

**Numbers:** signed 64-bit integers only, −9223372036854775808 to
9223372036854775807, canonical base-10; no fractions, no exponent notation, no
NaN, no infinity.

**Strings:** strict UTF-8, valid Unicode scalar values, reject U+0000, reject
unpaired surrogates, **no Unicode normalisation**, exact scalar sequence
preserved.

**Object keys:** same validity rules, exact decoded identity, no case folding,
no normalisation, deterministic UTF-8 byte ordering in canonical
serialisation, duplicate detection **before** canonicalisation.

Capability schemas are **closed by default**: unknown fields rejected, optional
fields explicitly declared, schema version selected by the capability
definition and never by the payload. For every `CINV` the payload schema
version is **immutable at authorisation**.

## 11. Result and output contract

Authoritative result: `/kyri/output/result.json` — UTF-8, exactly one JSON
document, top-level object, duplicate keys rejected at any depth, maximum
**2 MiB**, collected descriptor-safe and no-follow, **never repaired or
normalised**.

**Execution success requires all of:** the workload actually started; a valid
terminal lifecycle; no timeout; no sandbox or policy violation; exit code 0; a
valid `result.json`; and a valid complete output tree. **A capability cannot
self-declare success.**

Nonzero exit is invocation failure. A valid result from a failed execution is
untrusted diagnostic material only. Missing result is `result_missing`;
malformed is `result_invalid`. **Timeout always fails**, even if a result
exists.

**Output tree** rooted at the writable `/kyri/output`: relative paths and
subdirectories permitted. Bounds — result 2 MiB; **32** regular files maximum;
**16 MiB** aggregate regular-file bytes; `stdout` 2 MiB; `stderr` 2 MiB.
`stdout`/`stderr` are diagnostic only and each may truncate independently with
an explicit `truncated=true`.

**Collector:** descriptor-relative, no-follow, regular files only by default;
rejects symlinks, hard-link anomalies, FIFOs, sockets, devices, traversal,
absolute paths, and directory-rename escape; enforces count, size, and
aggregate limits; validates the **complete** tree before accepting a result. It
extends `tools/common/trusted_source.py`, which already implements the
`openat` + `O_NOFOLLOW` component walk. **Any output-policy violation fails the
entire invocation, and a valid `result.json` does not override it.**

## 12. Fixed runtime profile

Adapter-owned. Capability and package metadata may influence **none** of it;
metadata attempting to do so **refuses the invocation** rather than being
ignored.

| Control | Value |
|---|---|
| Runtime | rootless Podman, direct CLI, no socket, no API |
| Network | `--network none` |
| Rootfs | `--read-only`, `--read-only-tmpfs=false` |
| Capabilities | `--cap-drop ALL` |
| Privilege | `--security-opt no-new-privileges` |
| Devices/GPU | none |
| Container identity | fixed non-root UID/GID from the image |
| `/tmp` | 16 MiB tmpfs, `noexec,nosuid,nodev` |
| Memory | 256 MiB, `--memory-swap` 256 MiB |
| CPU | 0.5 |
| PIDs | 64 |
| Wall timeout | 30 s |
| Termination grace | 2 s, then force kill |
| Global concurrency | 2 |
| Mounts | `/kyri/package` ro · `/run/kyri/input/payload` ro · `/kyri/output` rw |

Future network authority requires a separate governed capability, profile, and
schema.

## 13. Filesystem roots — explicit access contract

Per Deferred G, **no root inherits a mode by convention**.

| Path | Owner | Mode | `kyri-capability` | Purpose |
|---|---|---|---|---|
| `/data/kyri/capability-runtime/` | `cschott:cschott` | `0700` | none | runtime plane root |
| `…/staging/` | `cschott:cschott` | `0700` | none | canonical A4 staging |
| `…/execution/` | `cschott:cschott` | `0700` | none | capacity, lifecycle, CMUT, CADM state |
| `…/execution/cadm-counter` | `cschott:cschott` | `0600` | none | provisioned CADM counter |
| `…/execution/admin-records/` | `cschott:cschott` | `0700` | none | CADM ledger |
| `…/execution/inspection-audit/` | `cschott:cschott` | `0700` | none | inspection audit events |
| `…/quarantine/` | `cschott:cschott` | `0700` | none | forensic quarantine |
| `/data/kyri/capability-handoff/` | `cschott:cschott` | `0711` | traverse only | handoff parent — traverse to a named child, no enumeration |
| `…/<CINV>/` | `cschott:cschott` | `0555` | read+traverse | per-invocation handoff |
| `…/<CINV>/package/` | `cschott:cschott` | `0555` | read | verified package copy |
| `…/<CINV>/payload` | `cschott:cschott` | `0444` | read | canonical payload bytes |
| `…/<CINV>/out/` | `kyri-capability:kyri-capability` | `0700` | read+write | the one writable leaf |
| `<helper path>` and ancestry | `root:root` | non-writable by `cschott`, `kyri-capability`, any unprivileged user/group | execute | transition and admin helpers |

`0711` on the handoff parent is deliberate: the worker must traverse to a named
child because rootless Podman resolves bind-mount sources **as the execution
identity**, and must not enumerate siblings.

## 14. Handoff model

Canonical staging stays `0700 cschott:cschott` and unreachable to uid 999.

Per invocation the coordinator: copies the verified artefact **from the
descriptor already opened and verified** — no source-path reopen — into the
handoff; publishes atomically by `rename`; re-verifies the digest after
publication; then the helper establishes ownership.

**Copy, not hard link** — normative. A hard link aliases the canonical inode
into an execution-reachable directory, permissions live on the inode so
canonical and handoff cannot diverge, and an `unlink` would affect the
canonical link count.

Same-filesystem assumption: handoff and canonical staging are both under
`/data` (one XFS filesystem), verified through the backing-store contract
(§20). Collision on an existing `<CINV>` handoff is a **refusal** — one attempt
per `CINV`. Residue is reported, never silently removed. Reboot clears
`runroot` on tmpfs; handoff on `/data` survives and is reported.

## 15. Quarantine model

Failed or untrusted output may be copied **only** as quarantined forensic
evidence, into `/data/kyri/capability-runtime/quarantine/<derived per CINV>`,
coordinator-controlled, with **no execution-identity write authority**.

Quarantine evidence is permanently untrusted: it cannot become a capability
result, cannot influence Fabric, Trust, or Health, and cannot feed downstream
automated execution. Bounds: 2 MiB per file, 32 files, 16 MiB aggregate.

**Storage admission.** No automatic deletion in v1. Before collection, preserve
a physical reserve of `16 MiB + max(1 GiB, 5% of filesystem capacity)`.
Admission uses physical free space minus outstanding logical reservations. Each
active collection durably reserves 16 MiB. Admission is serialised by a
dedicated quarantine-capacity lock. The full reservation is held until the
terminal collection record is durably committed; actual usage never reduces it
incrementally; future admission always rechecks actual physical free space.

**Crash before the terminal manifest** is `quarantine_collection_incomplete`:
no resume, no append, no overwrite, no automatic deletion. The 16 MiB
reservation and the execution slot both remain held. Disposition
`retain-quarantine-incomplete` may seal only if the partial namespace is within
32 files / 2 MiB per file / 16 MiB aggregate; unexpected object, overflow, or
ambiguity is `quarantine_incomplete_integrity_failure`. The final v1 escape
hatch `retain-quarantine-residue` transfers an opaque tree to operator-managed
residue — no manifest, no continued enumeration, no deletion authority — after
which the logical reservation may release while physical free-space
measurement continues to account for the retained bytes naturally.

## 16. Lifecycle state machine

```
reserved → launch_authorized → [transition] → created
  → container_verified → start_authorized → started
  → running → terminal → classified → collected → cleaned → released
```

Capacity is consumed only when `reserved` is durably committed while holding
the capacity lock and the per-`CINV` lock. **Once `reserved` exists the `CINV`
is permanently consumed** — no rollback to unused, no automatic retry, no
re-execution.

`container_verified` and `start_authorized` are **separate durable commits**.
Only after `start_authorized` may the worker issue exactly one
`podman start <recorded immutable ID>`. There is never an automatic second
start attempt.

## 17. Container creation and start

**`podman create` then `podman start`. Never `podman run`.**

Container name is derived solely from `CINV` — `kyri-CINV-000042`. The name is
a **discovery key only, never identity authority**, permanently burned with the
`CINV`, never intentionally reused. The immutable Podman container ID is
authoritative once recorded.

**Pre-launch collision.** Before `launch_authorized` the deterministic name is
checked read-only. If occupied: `execution_container_name_collision`. Kyri
binds the collision to the observed immutable ID **only after immediate
re-verification that the name still resolves to the same ID**; if unstable,
`execution_container_name_collision_unstable` and no launch authority issues.
Stable collisions admit `retain-collision` or `destroy-collision`; unstable
collisions admit `retain-collision` only, with **no Kyri destruction
authority**. The `CINV` permanently fails; there is no retry.

**Creation crash gap.** After `launch_authorized`, if the container ID was not
persisted, the deterministic name may be used **solely for candidate
discovery**. A candidate is adopted only after passing the complete fingerprint,
exact `CINV` association, exact pinned image digest, expected profile, and
expected labels and versioning. Zero candidates is `execution_state_lost`;
mismatch or ambiguity fails closed. **No replacement creation.**

**Execution fingerprint.** Persist, before container creation, both the
canonical execution-profile SHA-256 and the explicit security-critical fields,
built from adapter-owned values only. Recovery independently reconstructs the
observed Podman profile and requires exact agreement on: immutable container ID
after adoption, `CINV` association, exact OCI digest, `CIMP`, adapter/schema/
profile identities, execution UID and user namespace, network none, read-only
rootfs, capabilities, no-new-privileges, PIDs, memory, CPU, mounts and their
RO/RW disposition, tmpfs policy, and the absence of prohibited devices and
sockets. Mismatch is `execution_identity_mismatch`, and nothing is started,
restarted, attached, harvested, or deleted automatically.

**Profile versioning.** Every execution records an integer
`profile_schema_version`. Recovery uses the verifier for that exact version.
Unknown or retired is `execution_profile_version_unsupported`; a missing
expected verifier is `execution_profile_verifier_unavailable`. Verifiers are
retained while any unresolved authoritative execution state references them,
and unresolved records are **never migrated** to newer profile semantics.

**Start authority and crash.** Crash after `start_authorized`: `Created` →
`execution_start_outcome_unknown`; `Running` → full reverify then
`start_reconciled_running`; terminal → full reverify plus proof the workload
actually started, then `start_reconciled_terminal`. **`Created` with exit 0
remains a never-started launch failure.** Lifecycle precedes `ExitCode`,
always.

**Lifecycle evidence.** Podman lifecycle state is the authoritative observation
source; the worker cannot self-attest a successful start. `StartedAt`,
`FinishedAt`, and coordinator timestamps are audit metadata, not standalone
authority, and are never wall-clock normalised. Contradictory evidence is
`execution_lifecycle_integrity_failure`, after which `ExitCode` and result are
not trusted.

**Timeout.** At 30 s the classification becomes timeout **permanently**. Issue
normal termination, wait at most 2 s, then force kill. Result and output remain
untrusted evidence. A timeout can never become success because the workload
exited during the grace period.

## 18. Recovery state machine

Recovery is **admin-mediated**, never automatic. Routine execution requires no
second transition mode; every post-crash Podman observation happens through the
interactive-authenticated administrative helper (§20), which is why no
recovery path needs the NOPASSWD transition helper.

| Observed state | Classification | Disposition |
|---|---|---|
| `launch_authorized`, no ID, no candidate | `execution_state_lost` | `acknowledge-state-lost` |
| `launch_authorized`, candidate matches fingerprint | adopt ID, continue | — |
| candidate mismatch/ambiguous | `execution_identity_mismatch` | retain |
| `start_authorized`, `Created` | `execution_start_outcome_unknown` | `retain-start-unknown` / `destroy-start-unknown` |
| `start_authorized`, `Running` | `start_reconciled_running` | continue |
| `start_authorized`, terminal + start proven | `start_reconciled_terminal` | classify |
| contradictory lifecycle | `execution_lifecycle_integrity_failure` | `retain-lifecycle-failure` / `destroy-lifecycle-failure` |
| container absent after authoritative existence | `execution_state_lost` | `acknowledge-state-lost` |
| absent during CMUT freeze | `execution_state_lost_during_mutation_freeze` | `acknowledge-state-lost` |

Cached volatile observations never become authority. Anything permanently
failed is never re-executed.

## 19. Cleanup state machine

A coordinator-controlled, separate lifecycle step: descriptor-safe, no-follow,
internally derived per-`CINV` roots only, no caller paths, and **no privileged
recursive deletion fallback**. Cleanup runs only after the required evidence or
administrative reconciliation is durably committed.

Failure is `execution_cleanup_incomplete`; the slot remains held. Dispositions
are `retain-residue` and `retry-cleanup`. `retry-cleanup` is interactive
authenticated, uses the same cleanup algorithm with no broader authority, and
permits unlimited numeric retries each separately authenticated and audited.
**No automatic retry. No `destroy-residue` in v1.**

## 20. Administrative reconciliation and CADM

One narrow interactive-authenticated administrative helper. **No `NOPASSWD`**,
no shell, no arbitrary paths, no arbitrary container IDs, no Podman argument
passthrough, no environment override.

Verbs: `retain` · `destroy` · `retain-residue` · `retry-cleanup` ·
`retain-collision` · `destroy-collision` · `retain-start-unknown` ·
`destroy-start-unknown` · `retain-lifecycle-failure` ·
`destroy-lifecycle-failure` · `acknowledge-state-lost` ·
`retain-quarantine-incomplete` · `retain-quarantine-residue` ·
`inspect-admin-integrity`.

Every mutating attempt receives a `CADM`: coordinator-controlled, six digits,
monotonic, gaps permanent, from a **provisioned** counter with no runtime
bootstrap or reset, rollback detection, and fail-closed exhaustion.

Ordering: durable intent → **one** bounded side-effect attempt → durable
outcome. A crash between them is `intent-with-unknown-outcome`. **Never
automatic replay**; a new authenticated retry is a new `CADM`.

Storage: `CADM-nnnnnn/{intent, outcome?, reconciliations/}`. `intent` and
`outcome` are create-once immutable — no replacement, no rewriting.
`reconciliations` entries are create-once immutable with a local six-digit
sequence derived from the immutable existing records — **no mutable per-CADM
counter** — per-CADM serialised, fail-closed on exhaustion.

**Integrity.** Canonical admin namespace corruption blocks CADM allocation and
mutation globally: `administrative_record_integrity_failure`, or
`administrative_record_unexpected_object` for an unexpected object.
`inspect-admin-integrity` is interactive authenticated, read-only, fixed scope,
allocates no CADM, is available at any time, is metadata-only, bounded to a
2 MiB canonical summary and a 10,000-entry scan ceiling counting every
directory entry, deterministically ordered, with no pagination, no filtering,
and no repair verbs. Truncation is
`administrative_integrity_findings_truncated`; scan overflow is
`administrative_integrity_scan_limit_exceeded`; either blocks mutation.
Inspection itself creates a bounded durable audit event **outside** the CADM
ledger, which **must commit before the summary is emitted**; if that commit
fails, `inspection_audit_commit_failed` and the authoritative summary is
withheld.

**Destructive rule.** Destruction authority is always narrower than discovery
authority: an admin destruction may target only an immutable object already
durably bound to the relevant condition, and names or labels never substitute
for the immutable ID. If the target disappears after authorisation, record the
exact absent-object disposition and **never delete a replacement**. No
`podman system prune`; runtime reconciliation removes no images, volumes, or
networks.

## 21. CMUT foundational durability interface

`CMUT-nnnnnnnnnnnn` covers authority-bearing mutations whose uncertain commit
could grant, repeat, release, reinterpret, or lose track of authority: `CINV`
lifecycle transitions, capacity reserve and release, quarantine reservations,
authoritative execution identity and profile commitments, and administrative
authority state where applicable.

It does **not** cover ordinary logs, metrics, non-authoritative diagnostics,
inspection audit, or caches. The foundational layer is **exempt from recursive
CMUT coverage** and has its own allocator, immutable intent, immutable outcome,
reconciliation, exact-byte commitments, and descriptor-anchored fsync
contracts.

Protocol: durable CMUT intent containing `CMUT`, the exact canonical target,
the target record and schema type, and the SHA-256 of the exact canonical
target bytes → **one** installation attempt with target fsync, rename, and
directory fsync → immutable CMUT outcome. An intent without an outcome means
the mutation outcome is unknown.

Recovery reopens the provisioned backing store, validates the exact target, and
requires **exact SHA-256 equality**; there is no replay, and malformed or
ambiguous state fails closed.

`mutation_journal_integrity_failure` freezes all new authority-bearing
mutations globally. Existing workloads may finish naturally, read-only
observation is allowed, and **no state is promoted** until CMUT is restored.

**CMUT recovery is out of scope for this adapter** and requires a separate
offline root governance ceremony. This specification defines only the interface
and the stop conditions; the ceremony is not designed here.

## 22. Backing store contract

Every security-critical writable root beneath `/data` requires shared
backing-store verification before authoritative mutation. Provisioned
root-owned immutable config records the filesystem UUID, the filesystem type
(currently `xfs`), and the canonical `/data` mount relationship. **Device names
are diagnostic only.** The runtime can neither generate nor update this config.

Primary integrity is root ownership plus non-writable ancestry plus a
restrictive mode; secondary is a separately governed SHA-256 commitment.
Mismatch is `quarantine_backing_store_mismatch` or the appropriate shared
execution-runtime backing-store failure classification; config integrity
mismatch is `quarantine_backing_store_config_integrity_failure` or its shared
equivalent.

Every mutation: verify backing store → open the governed root directory
descriptor → verify descriptor filesystem identity → operate
descriptor-relative with **no pathname re-resolution mid-transaction** →
reverify descriptor filesystem identity → file fsync → atomic installation →
directory fsync → only then authoritative success.

## 23. Capacity and locking

Global maximum **2** active governed execution slots. **No queue.** A third
request is `execution_capacity_exhausted`. Quarantines consume the original
slot, so **two quarantines can halt all new execution**, and there are no
emergency slots.

A slot is reserved before container creation and held through handoff, create,
verify, start, execution, terminal classification, output collection, cleanup,
and reconciliation where required. Capacity authority lives in coordinator-owned
persistent state under `…/execution/`; the execution identity cannot mutate
capacity or lifecycle authority.

Ephemeral advisory locks carry **no durable authority**, lock files live
outside immutable authority-state namespaces, and file existence carries no
lifecycle meaning.

| Lock | Protects |
|---|---|
| global capacity | reservation and release decisions |
| per-`CINV` lifecycle | read → validate → decide → durable transition |
| quarantine capacity | quarantine admission and reservation |
| per-`CADM` | reconciliation sequence allocation |

**Order: global capacity → per-`CINV`. Never invert.** Workload execution does
not hold the lifecycle lock.

## 24. Crash boundaries

| Boundary | Outcome |
|---|---|
| before `reserved` | nothing consumed; retry is a new `CINV` |
| after `reserved`, before `launch_authorized` | `CINV` consumed; no container |
| after `launch_authorized`, no container ID | candidate discovery, else `execution_state_lost` |
| after create, before `container_verified` | fingerprint decides; mismatch fails closed |
| after `start_authorized` | §17 start reconciliation |
| during execution | Podman state authoritative on reconciliation |
| during collection | `quarantine_collection_incomplete` if forensic |
| during cleanup | `execution_cleanup_incomplete`, slot held |
| CMUT intent without outcome | mutation outcome unknown; no replay |

## 25. Classifications

**Execution:** `execution_capacity_exhausted` · `execution_container_name_collision` ·
`execution_container_name_collision_unstable` · `execution_state_lost` ·
`execution_state_lost_during_mutation_freeze` · `execution_identity_mismatch` ·
`execution_profile_version_unsupported` · `execution_profile_verifier_unavailable` ·
`execution_start_outcome_unknown` · `start_reconciled_running` ·
`start_reconciled_terminal` · `execution_lifecycle_integrity_failure` ·
`execution_cleanup_incomplete` · `execution_protocol_violation`.

**Result/output:** `result_missing` · `result_invalid`.

**Quarantine:** `quarantine_collection_incomplete` ·
`quarantine_incomplete_integrity_failure` · `quarantine_backing_store_mismatch` ·
`quarantine_backing_store_config_integrity_failure`.

**Implementation authority:** `implementation_authority_integrity_failure` ·
`implementation_authority_scan_limit_exceeded` ·
`implementation_authority_findings_truncated` ·
`implementation_authority_capacity_exhausted`.

**Administrative:** `administrative_record_integrity_failure` ·
`administrative_record_unexpected_object` ·
`administrative_integrity_findings_truncated` ·
`administrative_integrity_scan_limit_exceeded` · `inspection_audit_commit_failed`.

**Mutation:** `mutation_journal_integrity_failure`.

Outcome classes remain the released vocabulary of design §9 — `completed`,
`refused`, `adapter-error`, `provider-error`, `timeout`, `cancelled`,
`serialisation-failure`.

## 26. Audit and evidence

Every execution durably records: caller identity from the authenticated
transition, `CINV`, attempt identity, `CIMP`, exact OCI digest, artefact
digest, payload digest, `profile_schema_version` and execution-profile digest,
container name, immutable container ID, created and started timestamps,
terminal state, exit code where a start was proven, timeout or kill state,
result digest, output-tree manifest digest, and truncation flags.

**No secret content, no full payload, no full output** — digests and references
only, consistent with the released no-full-prompts rule. The invocation record
is durable **before** execution, so a crash always leaves evidence that the
invocation was attempted. Design §17 stands unweakened: **at-most-once
recorded, not exactly-once executed.**

## 27. Image availability and provisioning relationship

The exact digest MUST already exist in the `kyri-capability` rootless store
before execution; **there is no pull during invocation**, and absence is a
refusal, not a fetch. The image is admitted separately through governed
provisioning; the execution runtime cannot modify the allowlist.

Contents: one fixed exact Python patch version, standard library only, a fixed
non-root container UID/GID, purpose-built for Kyri — **no pip, no package
manager, no compiler or toolchain, no sudo, no SSH, no curl or wget, no
shell**, and nothing general-purpose beyond runtime needs. The absence of a
shell is compatible with §9 because Podman `exec`s the interpreter directly.

**The Track-B Alpine digest is TEST-ONLY and is never promoted.**

## 28. Implementation retirement relationship

Retirement is permanent and immediate on durability; removal is a later,
separate decision gated on retirement, zero unresolved references, and the
shared lifecycle serialisation (§5). An in-flight `CINV` already bound to a
retired `CIMP` remains valid — retirement governs *new* bindings only.

## 29. Deferred G interaction

The six existing `0755` coordinator data roots are **not modified** by this
increment and are not on the execution path. Every new root introduced here
carries an explicit owner, group, mode, and access contract in §13 rather than
inheriting one.

## 30. Future network authority boundary

V1 is `--network none`. Any future network execution requires a **new**
governed capability class, profile, schema, and authority contract — not a flag
on this one. The same applies to secrets (§31), devices, and GPU.

## 31. Security invariants

1. The only value crossing the privileged boundary is `CINV-nnnnnn`.
2. Root never runs Podman and never opens a caller-supplied path.
3. No Podman socket or API exists, for anyone.
4. The execution identity never writes authority state.
5. The capability never influences the runtime profile.
6. Container output is untrusted host filesystem input, always.
7. Lifecycle precedes `ExitCode`, always.
8. No automatic retry, replay, or re-execution, anywhere.
9. Every authority-bearing mutation is CMUT-covered.
10. Destruction authority is narrower than discovery authority.
11. Secret-free: an invocation requiring a secret refuses before execution.
12. Nothing flows back up — no execution result alters Fabric, Trust, or Health.

## 32. Attack matrix

| # | Attack | Prevented / detected where |
|---|---|---|
| 1 | option-looking or traversal `CINV` | `^CINV-[0-9]{6}$` in sudoers **and** revalidated in helper |
| 2 | helper or ancestor substitution | root-owned non-writable ancestry; sudo digest pin; `fdexec=digest_only` |
| 3 | `PATH` / `LD_PRELOAD` / `PYTHONPATH` manipulation | `env_reset`, no `SETENV`, absolute paths only |
| 4 | extra argv to helper | sudoers argument contract; helper accepts exactly one argument |
| 5 | caller-supplied path, image, mount, device, or flag | none crosses the boundary; profile is adapter-owned |
| 6 | payload in argv or environment | payload is a read-only mounted file only |
| 7 | package native code or extra entrypoint | package contract §8; one governed `.py` |
| 8 | symlink escape from package or output | descriptor-relative `O_NOFOLLOW` walk |
| 9 | output symlink attacking privileged reader | collector rejects non-regular files; Track-B Finding A |
| 10 | output count/size exhaustion | 32 files / 16 MiB / 2 MiB per file; violation fails invocation |
| 11 | `stdout`/`stderr` flood | 2 MiB each, independent truncation flags |
| 12 | fork bomb | `--pids-limit 64`, proven enforced in Track B |
| 13 | memory or CPU exhaustion | 256 MiB with OOM kill, 0.5 CPU, both proven |
| 14 | network exfiltration | `--network none`, proven: no route, DNS, or outbound |
| 15 | privilege escalation in container | `cap-drop ALL`, `no-new-privileges`, userns 0→999, seccomp |
| 16 | container name squatting | pre-launch collision check with immediate re-verification |
| 17 | container substitution after crash | complete fingerprint before adoption |
| 18 | replay of an invocation | `reserved` consumes `CINV` permanently |
| 19 | admin replay | one attempt per `CADM`; never automatic replay |
| 20 | destroying a replacement object | immutable-ID binding; absent-object disposition |
| 21 | forged worker report | closed protocol schema; worker writes no authority state |
| 22 | evidence-store corruption | integrity failures freeze globally, no runtime repair |
| 23 | disk exhaustion via quarantine | physical reserve + durable logical reservations |
| 24 | backing-store swap | UUID/type verification, descriptor identity reverified |
| 25 | capacity exhaustion as denial of service | accepted and explicit: 2 quarantines halt execution |

## 33. Fail-closed matrix

| Condition | Result |
|---|---|
| any grammar, schema, digest, or bound violation | refuse |
| unverifiable CIMP/CGEN state | global CIMP freeze |
| scan or summary overflow | integrity failure |
| CMUT journal failure | global mutation freeze |
| admin namespace corruption | global CADM freeze |
| backing-store mismatch | refuse mutation |
| identifier exhaustion (`CINV`/`CIMP`/`CGEN`/`CADM`/`CMUT`) | refuse |
| capacity exhausted | `execution_capacity_exhausted` |
| ambiguity anywhere | refuse; never guess |

## 34. Host prerequisites (described, not applied)

Root-owned transition helper and ancestry · root-owned administrative helper ·
two sudoers drop-ins (NOPASSWD transition with the `CINV` argument contract;
interactive-authenticated admin with fixed verbs) · root-owned immutable
backing-store config · provisioned `CADM` counter · `/data/kyri/capability-handoff`
per §13 · `…/execution/` and `…/quarantine/` per §13 · the admitted production
image present in the rootless store. **No systemd unit. No service. No daemon.**

## 35. Implementation stop conditions

Halt and request a ruling if: the helper would need broad A1–A5 semantics;
CMUT recovery appears to require design here; a second value would need to
cross the privileged boundary; the profile would need any caller influence;
Podman cannot express a control this profile requires; the authority-set cannot
fit both bounds; or any accepted decision conflicts with another.

## 36. Verification and acceptance criteria

1. `CINV` grammar rejected at both sudoers and helper layers, proven independently.
2. Helper refuses when the authorised transition context cannot be established.
3. Root demonstrably never execs Podman.
4. Worker demonstrably cannot write any authority root.
5. Profile fields verified against observed Podman state, field by field.
6. Payload canonicalisation rejects duplicates at depth, non-integer numbers, U+0000, unpaired surrogates.
7. Output collector rejects symlink, FIFO, socket, device, traversal, and over-bound trees.
8. Timeout classification is permanent across a grace-period exit.
9. `Created` with exit 0 classifies as launch failure.
10. Capacity honours 2 and refuses the third.
11. Lock order is enforced and inversion is impossible by construction.
12. Every authority mutation has a CMUT intent and outcome.
13. Crash injection at each §24 boundary yields the specified classification.
14. No adapter path exists that reaches Fabric, Trust, or Health.
15. Package-wide backstop proves no new execution authority beyond this adapter.

## 37. Related records

- [Execution transition boundary](2026-08-11-execution-transition-boundary.md)
- [Capability Runtime design](2026-08-10-capability-runtime-design.md)
- [Rootless execution prerequisite](../plans/2026-08-10-rootless-execution-prerequisite.md)
- [ENG-0005 non-executing implementation plan](../plans/2026-08-10-eng-0005-capability-runtime-implementation-plan.md)
