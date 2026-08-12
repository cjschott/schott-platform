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

`CIMP` identifies the *governance decision*; `oci_image_id` identifies the
*immutable bytes*. One governed implementation version maps to exactly one
image ID.

**`oci_image_id`, ruled 2026-08-12 and implemented.** The admitted execution
identity is the **immutable local image ID** — what `podman image inspect`
reports as `.Id` — written as **bare lowercase hex**, `^[0-9a-f]{64}$`, with no
algorithm prefix. The post-create readback is `podman container inspect`
`.Image`, which reports the same identity for the container actually created.

Explicitly **not** execution authority: an image's `.Digest` or `.RepoDigests`,
a container's `.ImageDigest`, `.RepoTags`, `.ImageName`, any tag, any
repository name, and any registry manifest digest. All of these describe how an
image *arrived* rather than what it *contains*; `.RepoDigests` is plural and
empty for a locally built image, and a manifest digest changes when a manifest
is re-serialised while the bytes do not.

The bare form is load-bearing rather than cosmetic: every non-authoritative
value above arrives `sha256:`-prefixed, so requiring no prefix makes each of
them **structurally unrepresentable** wherever `oci_image_id` is required,
instead of merely discouraged. A prefixed value is refused, not stripped.

This supersedes the earlier field name `oci_digest`, whose syntax admitted a
manifest digest and whose observation path read `.ImageDigest`. No production
`CIMP` had been admitted, so no migration path was owed and none was kept.

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
cschott → sudo /usr/libexec/kyri-exec-transition CINV-nnnnnn
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
modes and establish the ownership root cannot; then the credential sequence
below.

**The credential sequence, in this exact order.** Nothing here is reordered for
convenience; each step exists because the one before it has already happened.

1. `setgroups([987])` — supplementary groups restricted before anything else,
   because dropping uid first would make this impossible.
2. `setgid(987)`
3. `setuid(999)` — after the gid, since the reverse order loses the privilege
   needed to set the gid.
4. **verify** real, effective, and saved uid/gid and the group set, refusing if
   any component still carries privilege.
5. `PR_SET_NO_NEW_PRIVS` — **after** the permanent drop. The operation does not
   require root, so there is no reason to exercise it while the process still
   holds uid 0.
6. **verify** `PR_GET_NO_NEW_PRIVS == 1`. Calling the setter and assuming it
   worked is not setting it.
7. final privilege-loss verification.
8. `execve` the worker with an explicitly constructed environment.

**The `no_new_privs` mechanism is `ctypes` calling libc `prctl(2)`, and only
that.** Python 3.12 exposes no binding for `PR_SET_NO_NEW_PRIVS`, and the
alternatives each cost more than they save: a C helper adds an installed
binary, a build step, an integrity object, and a provisioning item; `setpriv`
reintroduces a subprocess and an exec before the drop; moving the bit to the
worker changes the accepted transition boundary. `ctypes` adds **no new host
artefact** — it reaches the system libc already loaded by the running
interpreter.

The exception is narrow and does not legalise FFI in the helper generally:

| Constraint | Value |
|---|---|
| Constants | `PR_SET_NO_NEW_PRIVS = 38`, `PR_GET_NO_NEW_PRIVS = 39` |
| Setter | `prctl(38, 1, 0, 0, 0)` |
| Getter | `prctl(39, 0, 0, 0, 0)`, must return `1` |
| Library binding | the current process only — never a caller-selected path |
| Symbols | `prctl` and nothing else |
| Wrappers | none: no `call_libc(name, *args)`, no dynamic symbol names, no reusable FFI abstraction |
| Scope | the privileged action module only; policy code and the execution package remain forbidden from importing `ctypes` |

Any setter or verification failure refuses before `execve`.

**The worker environment is exactly two variables**, promoted from the
validated Track-B configuration and adapter-owned:

```
HOME=/data/kyri/capability
XDG_RUNTIME_DIR=/run/user/999
```

That is the complete v1 set. No `CONTAINERS_*`, `XDG_DATA_HOME`,
`XDG_CONFIG_HOME`, `DOCKER_HOST`, `CONTAINER_HOST`, or storage override is
added: with `XDG_DATA_HOME` unset, rootless Podman derives storage from
`$HOME/.local/share/containers/storage`, which is the graphroot Track B
provisioned and proved, and `XDG_RUNTIME_DIR` carries its rootless runtime
state. Nothing is inherited — `/usr/bin/podman` is absolute, so `PATH` is not
execution authority.

**Bind-mount sources are compiled-in paths derived from the validated `CINV`**,
not descriptors:

```
/data/kyri/capability-handoff/CINV-nnnnnn/package   → /kyri/package   (ro)
/data/kyri/capability-handoff/CINV-nnnnnn/payload   → /run/kyri/input/payload (ro)
/data/kyri/capability-handoff/CINV-nnnnnn/out       → /kyri/output    (rw)
```

Podman's bind interface consumes a host pathname, so one must exist. It is
adapter-owned constant plus fixed-grammar `CINV` — never supplied by the
caller, payload, protocol, or package. `/proc/self/fd/N` is **rejected**:
descriptor resolution through Podman's helper and runtime process chain is
unvalidated here, and depending on it would add an undocumented platform
dependency.

Before building the create arguments the worker **re-establishes the handoff
boundary descriptor-safely**: compiled-in root → validated `CINV` → no-follow
open and stat → expected type, mode, and access → expected package and payload
identity → only then the fixed bind-source string.

**`HandoffBinding` stays path-free.** T7's descriptor proved publication
reached the trusted object; the worker is a different process after the
privilege transition, and only descriptors 0, 1 and 2 survive it, so descriptor
continuity cannot cross the boundary in any case. The worker re-establishes
trust from the fixed root, the validated `CINV`, and the immutable commitments
— and the derived pathname is a Podman argument, not filesystem authority
arriving from outside.

Nothing else crosses the transition: argv is
`(/usr/bin/python3, /usr/libexec/kyri-exec-worker.py, CINV-nnnnnn)`, the
environment is the two variables above, and the protocol is descriptors 0, 1
and 2.

**Inherited descriptors are exactly `(0, 1, 2)`**: stdin carries
coordinator→worker protocol, stdout carries worker→coordinator protocol, and
stderr carries bounded diagnostics. There are no dedicated protocol descriptors
in v1, and everything else is closed before the drop.

**The installed paths are fixed, because "the worker" was previously unnamed.**

| Constant | Value | Ownership and mode |
|---|---|---|
| `HELPER_PATH` | `/usr/libexec/kyri-exec-transition` | `root:root`, executable |
| `WORKER_INTERPRETER` | `/usr/bin/python3` | distribution-owned |
| `WORKER_SCRIPT` | `/usr/libexec/kyri-exec-worker.py` | `root:root`, mode `0444` |

The worker script is **not directly executed** and carries no executable bit:
the interpreter is named explicitly and the script is passed to it as an
argument. That removes the shebang line from the trust chain entirely — a
script that cannot be executed cannot be executed by the wrong interpreter, and
a mode of `0444` means the question of who may run it never arises.

The execution tuple is exactly:

```
execve("/usr/bin/python3",
       ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py", "CINV-nnnnnn"),
       CLOSED_ENVIRONMENT)
```

Neither path is ever selected through `PATH`, and neither is ever loaded from
the repository checkout — `tools/capability/execution/worker.py` is source, and
source is not an installed executable. Everything else the worker needs arrives
through inherited descriptors and internally derived roots.

**Root MUST NOT:** run Podman; construct container argv from caller input;
accept a caller-supplied path, image, mount, environment, or runtime/resource
flag; expose a shell or a generic user-switch; implement selection; call Trust
or Health; mutate Fabric; or become a general Capability Runtime API.

**Schema stop condition.** If the helper would need broad A1–A5 semantics to
determine `launch_authorized`, that is a **halt-and-rule event**, not a design
problem to solve by growing the helper. The mitigation is a single
coordinator-written, create-once **launch authorisation record** whose schema
the helper reads: `CINV`, `CIMP`, `oci_image_id`, handoff root, profile schema
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

**Traversal bounds — maximum depth 16, maximum 256 total entries.** Added
2026-08-12; the original bounds counted regular files and their bytes only.
Those two shapes of exhaustion are independent of this one: a tree with **zero**
regular files satisfies every byte and file limit above while presenting an
arbitrarily deep directory chain, or one directory holding millions of empty
children, and traversal exhausts descriptors, stack, or time before any file
bound is ever consulted.

Depth 0 is the output root; an entry directly beneath `/kyri/output` is at
depth 1; nothing may exist deeper than depth 16. **Every** enumerated directory
entry counts toward the 256 ceiling whatever its type — regular file,
directory, symlink, FIFO, socket, device, or unexpected object — because an
object refused for its type has still been enumerated, and a ceiling that
counted only the acceptable ones would not bound the work. The root itself is
not an entry. Enumeration stops when entry 257 is encountered rather than
completing the scan and reporting afterwards.

The regular-file limits remain independent and are enforced alongside these:
32 files, 2 MiB per file, 16 MiB aggregate. 256 entries and 16 levels leave
room for legitimate nested diagnostic output while staying far below the §8
package and §20 administrative scan ceilings; a capability with 32 useful files
does not need thousands of directory nodes.

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
| Python environment | `PYTHONHASHSEED=0` · `PYTHONUTF8=1` · `LC_ALL=C.UTF-8` · `PYTHONDONTWRITEBYTECODE=1`, fixed `--env`, inherited from nothing |
| Output quota | project `1_000_000 + CINV`, 32 MiB / 512 inodes on `out/` (§34) |
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

**Structural bounds — the same hostile-tree contract as §11.** Ruled
2026-08-12: maximum depth **16**, maximum **256** total entries, the root at
depth 0 and not itself an entry, every encountered child counted whatever its
type, and entry 257 refused immediately. The content limits above — 32 regular
files, 2 MiB per file, 16 MiB aggregate — remain independent of these.

Quarantine traversal reuses `tools/common/trusted_source.walk_tree` rather than
introducing a second walker, so normal output collection and quarantine sealing
rest on one audited filesystem-safety primitive. A second bespoke geometry would
mean two hostile-tree contracts to keep correct, and the one that is exercised
less often is the one that would rot.

**Crash before the terminal manifest** is `quarantine_collection_incomplete`:
no resume, no append, no overwrite, no automatic deletion. The 16 MiB
reservation and the execution slot both remain held. Disposition
`retain-quarantine-incomplete` may seal only if the partial namespace is within
32 files / 2 MiB per file / 16 MiB aggregate **and within the depth and entry
bounds above**; unexpected object, overflow, depth or entry violation, hard-link
anomaly, or ambiguity is `quarantine_incomplete_integrity_failure`. No new
classification is added: that member already means the partial namespace cannot
be safely sealed as validated forensic evidence, and the operator's fallback is
unchanged — `retain-quarantine-residue` turns the whole tree into opaque
operator-managed residue with no further enumeration. The final v1 escape
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
after adoption, `CINV` association, exact `oci_image_id`, `CIMP`, adapter/schema/
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

**Deletion-work bounds — maximum depth 32, maximum 8,192 total entries.** Ruled
2026-08-12, and deliberately larger than the §11 and §15 figures: those are
acceptance limits for output that might be trusted, while cleanup exists to
face residue that has *already* violated them. The bounds apply to the whole
internally derived per-`CINV` handoff subtree —`package/`, `payload`, `out/`,
directories, and every unexpected object. The `CINV` root is depth 0 and is not
itself an entry, direct children are depth 1, nothing below depth 32 is
traversed, every encountered entry counts whatever its type, and entry 8,193
stops traversal immediately. There is no pagination, no continuation cursor,
and no "remove the first 8,192 and return later".

Exceeding either bound is `execution_cleanup_incomplete`: stop deleting, do not
broaden traversal, do not retry, keep the `CINV` consumed and its slot held, and
preserve what remains. Partial deletion before the bound was reached is
acceptable only because cleanup is idempotent over its own internally derived
subtree; what is left is still residue, and a later `retry-cleanup` runs the
same bounded algorithm with no broader authority.

Cleanup does **not** reuse the §11 collection primitive. That primitive reads
file contents because its purpose is evidence, which is the wrong tool for
removal; the cleanup walker is descriptor-relative, streaming, post-order, and
reads no regular-file bytes at all.

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
| after `reserved`, before `launch_authorized` | `CINV` consumed; no container. A transition or helper failure here, with `launch_authorized` provably not issued, is `transition_failed_before_execution` |
| after `launch_authorized`, no container ID | candidate discovery, else `execution_state_lost` |
| after create, before `container_verified` | fingerprint decides; mismatch fails closed |
| after `start_authorized` | §17 start reconciliation |
| during execution | Podman state authoritative on reconciliation |
| during collection | `quarantine_collection_incomplete` if forensic |
| during cleanup | `execution_cleanup_incomplete`, slot held |
| CMUT intent without outcome | mutation outcome unknown; no replay |

## 25. Classifications

**Execution:** `execution_capacity_exhausted` · `execution_image_unavailable` ·
`transition_failed_before_execution` · `execution_container_name_collision` ·
`execution_container_name_collision_unstable` · `execution_state_lost` ·
`execution_state_lost_during_mutation_freeze` · `execution_identity_mismatch` ·
`execution_profile_version_unsupported` · `execution_profile_verifier_unavailable` ·
`execution_start_outcome_unknown` · `start_reconciled_running` ·
`start_reconciled_terminal` · `execution_lifecycle_integrity_failure` ·
`execution_cleanup_incomplete` · `execution_protocol_violation`.

**`execution_image_unavailable`** — the exact immutable `oci_image_id` bound to the
governed `CINV`/`CIMP` execution contract is not present in the
`kyri-capability` rootless store at a required availability check. It
authorises **no** pull, registry access, mutable-tag lookup, substitute digest,
newer implementation, different `CIMP`, automatic provisioning, or retry using
different executable bytes. Pre-reservation detection consumes **no** execution
slot. If the second required check fails after `reserved` but before
`launch_authorized`, the `CINV` remains consumed and follows the governed
pre-launch failure and cleanup path.

**`transition_failed_before_execution`** — used **only** when the `CINV` has
already entered execution lifecycle authority, transition or helper processing
fails, `launch_authorized` has **not** been durably issued, and Kyri can
therefore prove no governed container creation authority was issued. The `CINV`
remains permanently consumed: no rollback to unused, no automatic retry, and no
new transition attempt for the same `CINV`. Capacity may release after durable
terminal classification and governed cleanup. **If `launch_authorized` may have
been issued, or execution cannot be excluded, this classification MUST NOT be
used** — enter the corresponding fail-closed reconciliation path instead.

**Result/output:** `result_missing` · `result_invalid` ·
`output_tree_policy_violation`.

**`output_tree_policy_violation`** — added 2026-08-12. Every **structural**
output-tree refusal: depth beyond 16, more than 256 total entries, a 33rd
regular file, aggregate beyond 16 MiB, a regular file beyond 2 MiB, a symlink,
FIFO, socket, or device, a hard-link anomaly, a traversal or type race, and any
other forbidden tree structure.

It is deliberately **separate** from the two result classifications, which keep
their existing and narrower meanings. `result_missing` means the complete tree
was structurally valid and the canonical root-level `result.json` was absent;
`result_invalid` means that file existed and failed its document contract.
Folding structural refusals into `result_invalid` would make it a catch-all in
which a hostile filesystem shape and a malformed document are indistinguishable
— and the first is an attack on the privileged reader while the second is a
capability bug.

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
transition, `CINV`, attempt identity, `CIMP`, exact `oci_image_id`, artefact
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
refusal, not a fetch — classified `execution_image_unavailable` (§25). The
image is admitted separately through governed provisioning; the execution
runtime cannot modify the allowlist.

Contents: one fixed exact Python patch version, standard library only, a fixed
non-root container UID/GID, purpose-built for Kyri — **no pip, no package
manager, no compiler or toolchain, no sudo, no SSH, no curl or wget, no
shell**, and nothing general-purpose beyond runtime needs. The absence of a
shell is compatible with §9 because Podman `exec`s the interpreter directly.

**These are properties of the final runtime image**, clarified at the G4 ruling
of 2026-08-12. They do not forbid a build stage from carrying tooling; the
earlier reading, which forbade the definition from mentioning it at all, was
stronger than intended and unsatisfiable. For the v1 image no build stage is
needed, because the admitted base already is the runtime.

**Base family and pinning, ruled 2026-08-12.** The minimal Chainguard Python
runtime (`cgr.dev/chainguard/python`), whose runtime variant has no shell and no
package manager and configures its interpreter at **`/usr/bin/python`**. T12's
`CONTAINER_INTERPRETER` was corrected from `/usr/bin/python3` to match, rather
than the image being deformed to preserve a pathname — keeping the old name
would have meant carrying a package manager into the final image purely to
create it. The host-side `WORKER_INTERPRETER` is a different thing and is
unchanged.

The authoritative definition names **no base**: `BASE_IMAGE` is a build argument
with no default, and the G5 procedure accepts only
`cgr.dev/chainguard/python@sha256:<64-hex>`. A tag may be used during
provisioning discovery to identify a candidate digest and must never reach a
build, because the vendor's tags float.

**Governed Python is 3.14.6.** Admission must independently prove all three of:
the OCI base digest equals the expected candidate; the SBOM reports Python
3.14.6; and `/usr/bin/python` reports 3.14.6. Any disagreement refuses
admission. A distribution package revision (`-rN`) may differ as the vendor
rebuilds the same upstream version — the OCI digest identifies the artefact
while `3.14.6` fixes the governed upstream semantics.

**`/usr/bin/python` may be a symlink.** The whole image filesystem, link and
target together, is committed by the immutable OCI digest, which is stronger
evidence than forbidding symlinks would be. Admission verifies that it resolves
entirely inside the image rootfs, traverses nothing outside it, terminates at a
regular executable file, and reports 3.14.6; and records as provisioning
evidence the image digest, the link value, the resolved target path, the SHA-256
of the resolved interpreter, the reported version, and the SBOM Python package.

**The image default user is not execution authority.** The base defaults to
`65532:65532`; T12 launches every container with an explicit `--user 1000:1000`
and the profile verification compares what Podman reported against that, so the
image's own default is metadata.

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
| 10a | output tree depth or entry exhaustion | depth 16 / 256 total entries of every type; independent of the file bounds |
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
| bound image digest absent from the rootless store | `execution_image_unavailable`; never pull, never substitute |
| transition fails with `launch_authorized` provably not issued | `transition_failed_before_execution`; `CINV` stays consumed |
| transition fails and execution cannot be excluded | **not** `transition_failed_before_execution` — fail-closed reconciliation (§18) |
| ambiguity anywhere | refuse; never guess |

## 34. Host prerequisites (described, not applied)

Root-owned transition helper and ancestry (`/usr/libexec/kyri-exec-transition`) ·
**root-owned worker script** (`/usr/libexec/kyri-exec-worker.py`, mode `0444`,
executed by `/usr/bin/python3`) ·
root-owned administrative helper ·
two sudoers drop-ins (NOPASSWD transition with the `CINV` argument contract;
interactive-authenticated admin with fixed verbs) · root-owned immutable
backing-store config · provisioned `CADM` counter · `/data/kyri/capability-handoff`
per §13 · `…/execution/` and `…/quarantine/` per §13 · the admitted production
image present in the rootless store. **No systemd unit. No service. No daemon.**

**Per-`CINV` output containment — resolved 2026-08-12 at the G4 review.** §12
bounds memory, CPU, and PIDs and §11 bounds what collection will *accept*, but
nothing bounded what a workload may *write* into the read-write `/kyri/output`
mount during its 30 seconds. XFS project quotas close that, applied to the
`out/` leaf **only** — never the whole handoff tree, since §8 permits a package
of 64 MiB and 1,024 entries and a tree-wide quota would refuse packages the
package contract already accepted.

| Control | Value |
|---|---|
| Scope | `/data/kyri/capability-handoff/<CINV>/out` |
| Project ID | `1_000_000 + numeric part of CINV` — derived, never allocated |
| Hard block limit | 32 MiB |
| Hard inode limit | 512 |

The limits are a **write-time envelope at twice the §11 acceptance policy**, so
a capability that writes a temporary file and renames it over its result is not
failed for behaving ordinarily, while a workload cannot consume gigabytes or
millions of inodes before anything judges its output. `CINV` identities are
never reused, so derived project IDs never alias; project 0 is never produced,
because 0 is the filesystem default and would silently mean *unlimited*.

**Mechanism, chosen with the care `no_new_privs` was.** Two halves, split so
that only one of them is a runtime privilege:

- **Limits are provisioned, once, by an operator at G4:**
  `xfs_quota -x -c 'limit -p -d bhard=32m ihard=512' /data`, which sets the
  filesystem's *default* project limits. Enforcement requires `prjquota` on
  `/data`, verified at provisioning.
- **The runtime privileged operation is a single `ioctl`.** With the limits
  already default, the runtime only states *which project a tree belongs to*:
  `FS_IOC_FSSETXATTR` with `fsx_projid` and `FS_XFLAG_PROJINHERIT` on the
  already-open, empty `out/` descriptor, read-modify-write so no other flag is
  disturbed. Inheritance makes it one-shot — every file the workload creates is
  accounted by the filesystem, with no tree walk and no second pass.

This deliberately keeps `quotactl` and `xfs_quota` **out of the runtime path
entirely**. There is no subprocess, no shell, and no `ctypes`: `fcntl.ioctl`
and `struct` are standard library. The privileged source is
`provisioning/execution/kyri-exec-quota.py`, installed by nothing, and it takes
**one validated `CINV`** — no path, no project ID, no limit — reaching the leaf
descriptor-relative from a compiled-in root. It does not import the runtime
package: root reading from a tree the execution identity can influence is the
wrong direction.

Policy shared by both sides lives in `tools/capability/execution/quota.py`,
which is pure and sets nothing.

**Wired into the transition, not optional.** Ruled 2026-08-12: establishing the
project is a mandatory step between handoff preparation and the credential drop.

```
T10 policy accepted → verify/open exact CINV handoff
  → establish XFS project on out/ → verify projid + PROJINHERIT
  → close descriptors not inherited
  → setgroups → setgid → setuid → verify permanent drop
  → set + verify no_new_privs → execve worker
```

The invariant this buys: **the worker can never reach Podman unless its
`/kyri/output` backing directory is already bound to the deterministic `CINV`
project.** `perform_transition` takes the quota component as a required
collaborator with no default, so an unquotaed execution is not a path anybody
could forget to take — there is no signature that reaches `execve` without one.

Any of these prevents the drop: the expected filesystem absent, project quotas
not enabled, `out/` missing or the wrong type, an existing foreign project
assignment, the ioctl failing, a project that disagrees with the `CINV`, a
readback that does not confirm, or `PROJINHERIT` unset. Every one occurs before
any privilege is spent, so execution is conclusively excluded and the refusal is
`transition_failed_before_execution`. **There is no fallback to unquotaed
execution:** a quota failure costs availability, never containment.

Verification never trusts the setter. After `FS_IOC_FSSETXATTR` the attributes
are read back with `FS_IOC_FSGETXATTR` and must show the exact project,
inheritance set, and every unrelated xflag exactly as it was.

The privileged operation stays a **separate component**
(`provisioning/execution/kyri-exec-quota.py`), invoked through a fixed seam
rather than inlined, so the transition helper does not become a filesystem
administration interface. Its effective authority remains: validated `CINV` →
internally derived `out/` descriptor → deterministic project ID → exactly one
`FS_IOC_FSSETXATTR`.

**Still required at G4 provisioning:** `prjquota` enabled and verified on
`/data`, and the default project limits established, **before** the first real
G6 execution. Until both hold, the containment is defined but not enforced, and
the partial mitigations stand: §19's deletion-work bounds cap removal cost, the
30-second timeout caps how long residue can be generated, and `/data` free
space remains an operational signal.

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
7. Output collector rejects symlink, FIFO, socket, device, traversal, and over-bound trees, including trees over-bound by depth or entry count alone.
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
