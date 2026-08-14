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

### 5.1 Interrupted admission and namespace classification

**Ruled 2026-08-12. REQUIRED BUT NOT YET IMPLEMENTED** — the live reader still
treats every published-but-unlisted CIMP as a global integrity failure, and the
writer does not exist. Nothing below describes current runtime behaviour.

Admission publishes a CIMP record and then advances `current-generation`. Those
are two atomic steps, so an interruption between them is reachable by ordinary
power loss. Because the reader cross-checks the implementations namespace
against the current authority set, that window would otherwise freeze
implementation authority globally — making a routine crash require the
extraordinary recovery ceremony reserved for corruption.

**Publication and authority stay distinct.** Publication makes an object
immutable; `current-generation` decides what is authoritative. Existence never
grants authority. The reader therefore classifies the namespace into three
states rather than two.

**VALID.** The current generation completely accounts for every published CIMP:
each is represented in the current authority set either as eligible under the
existing admission rules or as retired under the existing retirement rules. No
published-but-unlisted CIMP exists. This is the only ordinary steady state.

**VALID_WITH_PENDING_DISPOSITION.** One or more published CIMP admissions are
structurally sound but unaccounted for by the current generation. A CIMP is
*pending* only when **all** of these hold: the identifier is syntactically
valid and is not `CIMP-000000`; the directory contains no unexpected object and
no prohibited symlink; the admission record parses as canonical bytes,
validates against the closed schema, and its digest validates; its governed
commitments validate as normally required; the CIMP is absent from the current
authority set; its ordinal is strictly greater than the current high-water
mark; and no current authority derives from it.

Pending CIMPs are **interrupted transactions awaiting disposition** — not
eligible, not authorised, not retired by implication, never automatically
included in a later authority set, never automatically deleted, never
automatically repaired. They must never resolve as execution authority.

**Two pending subtypes, ruled 2026-08-12.** A pending CIMP carries which
disposition it is waiting for, because the two permit different completions and
re-deriving the difference from raw namespace bytes would be a second
interpretation of the same evidence.

- **`PENDING_ADMISSION`** — a published admission with no retirement record.
  The interrupted admission has received no final decision, so the operator may
  still choose **COMPLETE** or **RETIRE**. Neither happens automatically.
- **`PENDING_RETIREMENT`** — a published admission *and* a valid published
  retirement for the same CIMP. The RETIRE decision is already immutable, and
  the only lawful completion is publishing a successor generation that accounts
  for the CIMP as retired. **COMPLETE is forbidden**: an immutable retirement is
  not reversible, and no later operator may make such a CIMP eligible.

A published retirement does **not** by itself make a CIMP accounted for. Only a
current authority set listing it with the correct admission and retirement
commitments completes the disposition.

**The RETIRE ceremony has its own crash window**, and it is tolerated for the
same reason the admission window is. The ceremony publishes the retirement
record and then publishes the successor generation; a crash between them leaves
a valid admission and a valid retirement with no generation accounting for
either. Treating that as corruption would recreate the ordinary-power-loss
global freeze this model exists to prevent. So: the namespace stays
VALID_WITH_PENDING_DISPOSITION, the subtype becomes `PENDING_RETIREMENT`,
already-current implementations remain usable, the pending CIMP stays
ineligible, ordinary writer mutation stays blocked, and disposition resumes by
publishing a fresh successor `CGEN` accounting for it as retired. No deletion,
no automatic repair, no identifier reuse, and no reversal to COMPLETE.

**A malformed retirement is not pending.** A retirement without a valid
admission beside it, one naming a different CIMP, one that is not canonical or
fails the closed schema, an unexpected extra object, or a symlinked record are
all INVALID and freeze globally. A future ordinal buys no leniency about
structure — tolerance is only ever about the *omission* from the authority set.
Runtime resolution continues against the already-current authority set, so
valid pending state does **not** disable implementations that are already
authoritative. That is the point of the classification: a crash must not
revoke authority that was correctly granted before it.

**INVALID.** Everything else, unchanged and global. `CIMP-000000` physically
present; a malformed identifier, admission, or retirement; non-canonical bytes;
any digest mismatch; a prohibited symlink; an unexpected object; a CIMP the
current authority set names but disk does not supply, or supplies altered; an
authority-set or generation mismatch; an unlisted CIMP whose ordinal is **less
than or equal to** the high-water mark; a pending candidate that fails any
structural or commitment check; and every pre-existing integrity finding.
INVALID freezes implementation authority globally, the writer refuses, nothing
is repaired automatically, and recovery remains a separate reviewed ceremony.

**High-water mark.** For a non-empty current authority set it is the maximum
numeric ordinal among **every** CIMP the set represents, retired entries
included. For the empty genesis authority set it is **0**, not −1, because
`CIMP-000000` is reserved and normal allocation begins at `CIMP-000001` — so
the first legitimately published CIMP still satisfies *ordinal > high-water*
while an ordinal-0 directory can never qualify as pending.

**`CIMP-000000` is permanently reserved.** The lexical parser may keep
recognising six digits generally, but governed semantic validation rejects
`CIMP-000000` wherever a real implementation identifier is required. Its
physical presence is an integrity finding: never pending, never eligible, never
automatically retired. This is unrelated to `CGEN-000000000000`, which remains
the legitimate genesis generation.

**Multiple pending CIMPs.** Under normal operation at most one can exist,
because the writer refuses ordinary mutation while any pending CIMP is present,
so a second interrupted admission cannot be started. Their physical presence is
still handled deterministically: the reader reports **all** pending
identifiers, the writer refuses ordinary mutation while any exists, and a
disposition ceremony must account for every one of them before the namespace
returns to VALID. None may disappear from accounting.

**All pending CIMPs must be dispositioned in a single successor generation.**
Disposing of them one generation at a time would raise the high-water mark past
a still-pending lower ordinal, which is precisely the INVALID condition above —
so a sequential ceremony would transit through global freeze. One ceremony, one
successor generation, every pending CIMP explicitly COMPLETE or RETIRE.

### 5.2 Disposition ceremonies

**COMPLETE** is permitted only for `PENDING_ADMISSION`. If a valid retirement
record exists for the CIMP the ceremony must refuse, and the reader's subtype is
what makes that enforceable without a second reading of raw namespace state.

**COMPLETE** resumes an interrupted admission. A valid admission record proves
only that the record was written, never that the later authority-publication
prerequisites ran, so the ceremony **re-performs** them: the §27 three-way
agreement — OCI base digest, SBOM Python version, and the interpreter's own
reported version — plus the provisioning-evidence commitment, before any
authority is granted. On success it allocates a fresh `CGEN`, constructs the
complete successor authority set listing the pending CIMP as eligible,
publishes the immutable generation, atomically replaces `current-generation`,
reads back through the normal reader, and proves the CIMP resolves exactly as
intended. **The original CIMP identifier is retained**; COMPLETE never
allocates a new one.

**RETIRE** decides that a published admission must never become eligible. The
existing grammar supports this without change: an authority-set entry carries
both an admission digest and a retirement digest, the reader validates both and
excludes the entry from `eligible`, and nothing requires the CIMP to have been
listed previously. The ceremony creates the normal immutable retirement record,
allocates a fresh `CGEN`, builds the complete successor authority set
representing the CIMP with **both** commitments, publishes, replaces the
pointer, and reads back to prove the CIMP is accounted for and ineligible.

RETIRE here means *published admission deliberately prevented from becoming
eligible*, which is not the same fact as *previously authorised implementation
later withdrawn*. The retirement record is a closed `{"cimp": …}` schema and
cannot carry that distinction, and it is not extended to: the generation chain
already preserves it. Generation directories are create-once and never removed,
and each generation names its predecessor and that predecessor's digest, so
walking the chain shows whether any earlier current authority set ever listed
the CIMP as eligible. The fact is recoverable from immutable history rather
than restated in a record that would then have to be trusted.

### 5.3 Published non-current generations

A successor generation can be published and never become current. This is
**not** the same as a superseded generation: every generation that the current
one descends from is also non-current, and treating "non-current" as pending
would make every namespace with history permanently pending. The distinction is
the ancestry chain — a generation reachable from `current-generation` by
following `predecessor_cgen` is history, and one that is not is an orphaned
interrupted-transaction artifact.

**The reader does not classify orphans; the writer reconciles them.** The
reader opens `generations/<CGEN>` by name and never enumerates the directory,
so an orphan is invisible to it — which is sound, because authority flows only
through `current-generation` and an orphan therefore grants nothing. Making the
reader walk the whole chain on every resolution would add cost and failure
modes to the runtime path for no security gain. The writer, which is offline
and already enumerating, refuses ordinary mutation while an orphan generation
exists and requires explicit disposition. A namespace may consequently be VALID
to the reader while the writer sees pending work; that asymmetry is intended
and safe, because pending state never grants authority.

**Disposition always allocates a fresh `CGEN`.** An orphan is never adopted,
even when its authority set would match the intended one: adopting would mean
proving byte-for-byte that a partially-completed transaction produced exactly
the generation now intended, which is extra verification for no security gain,
while `CGEN` identifiers are 12 digits and permanent gaps are already the rule.
The orphan remains as inert immutable state, accounted for by the ceremony and
never deleted or reused.

### 5.4 Staging and the publication boundary

Objects under root-only staging have not crossed the publication boundary, are
invisible to the reader, and grant nothing. Unexpected staging makes the writer
refuse ordinary mutation. A separate explicit unpublished-state cleanup action
may remove *verified* staging material; the normal writer never does it
automatically, and no cleanup may ever touch published CIMP or CGEN state. An
identifier already allocated stays burned even when its staging is discarded.

### 5.5 The normal admission transaction

Acquire the root-only lifecycle lock · require VALID and refuse if any pending
disposition or orphan generation exists · allocate the next `CIMP` and burn it ·
stage the admission · fsync · validate the staged canonical bytes and digest ·
atomically publish `implementations/<CIMP>/` · fsync `implementations/` · read
the published CIMP back · perform the authority-publication prerequisites in
full · allocate the next `CGEN` · build the complete successor authority set ·
stage the generation · fsync · validate · atomically publish the generation
directory · fsync `generations/` · read the non-current generation back ·
construct the canonical `current-generation` bytes · write the temporary
pointer · fsync it · atomically rename it over `current-generation` · fsync the
authority root · read the whole namespace through the normal reader · require
VALID · prove the intended CIMP resolves · release the lock.

The prerequisites are re-performed at authority-publication time rather than at
record-write time, which is what makes COMPLETE's re-verification meaningful:
publishing the admission record commits bytes, and only the generation commits
authority.

### 5.6 Crash-point matrix

Authority visible to runtime is the current generation at every row; no row
grants authority to an interrupted artifact.

| Crash point | Classification | Identifier burned | Ordinary admission allowed | Required action |
|---|---|---|---|---|
| before CIMP allocation | VALID | no | yes | none |
| after allocation, before staging | VALID | CIMP | yes | none; gap is permanent |
| during staging | VALID | CIMP | **no** | unpublished-state cleanup |
| after staged validation, before publication | VALID | CIMP | **no** | unpublished-state cleanup |
| after CIMP publication | PENDING | CIMP | **no** | COMPLETE or RETIRE |
| after CIMP publication and readback | PENDING | CIMP | **no** | COMPLETE or RETIRE |
| after CGEN allocation | PENDING | CIMP, CGEN | **no** | COMPLETE or RETIRE, fresh CGEN |
| during CGEN staging | PENDING | CIMP, CGEN | **no** | as above, plus staging cleanup |
| after generation publication, before pointer | PENDING + orphan CGEN | CIMP, CGEN | **no** | as above; orphan never adopted |
| during temporary pointer creation | PENDING + orphan CGEN | CIMP, CGEN | **no** | as above, plus staging cleanup |
| after pointer fsync, before rename | PENDING + orphan CGEN | CIMP, CGEN | **no** | as above |
| after pointer rename, before root fsync | VALID (pointer may not survive) | CIMP, CGEN | yes if VALID | re-read; if the pointer did not survive, treat as the row above |
| after root fsync, before final readback | VALID | CIMP, CGEN | yes | none; transaction succeeded |
| after readback, before lock release | VALID | CIMP, CGEN | yes | stale lock released on process exit |

### 5.7 Authority namespace on disk

Published authority lives at `/var/lib/kyri/implementation-authority`;
directories `root:cschott 0750` and immutable records `root:cschott 0440`.
`/var/lib/kyri` stays `root:root 0711`. Read — not merely traverse — is
required because the reader enumerates `implementations/`. The coordinator
reads and never writes; `kyri-capability` gets no access at all; every ancestor
is root-owned and non-writable by both, so neither can rename, replace, or
shadow the namespace.

Operator-only mutable control state is structurally separate, at
`/var/lib/kyri/implementation-authority-control` (`root:root 0700`), holding
`cimp-counter` and `cgen-counter` (`root:root 0600`), the `implementation-lifecycle`
lock (`root:root 0600`), and `staging/` (`root:root 0700`). The coordinator
requires no access to any of it. Keeping counters and lock outside the
published namespace means coordinator-invisibility is structural rather than
dependent on the reader happening not to enumerate the authority root.

**Immutable and create-once:** CIMP admission records, retirement records,
authority sets, generation records, and generation directories.
**Atomically replaceable:** `current-generation`, and only that. It is a
regular canonical-JSON file, never a symlink, read under the existing no-follow
discipline, and updated only by durable atomic replacement. It is a pointer,
not an immutable record, and must not be described as one.

**Counters** are independent, persistent, root-only, and monotonic. Allocation
never scans the namespace for a maximum. Identifiers are never reused, failed
or abandoned allocations burn theirs permanently, and gaps are valid and
expected. Normal allocation begins at `CIMP-000001` and `CGEN-000000000001`;
`CGEN-000000000000` is genesis, published with a valid empty authority set as
an explicit provisioning ceremony before any admission, and the counter must
never allocate it again. Runtime never creates genesis and never initialises a
counter.

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
modes and establish the ownership root cannot; **authenticate and seal the
governed profile as §14.1.7 orders it**; then the credential sequence below.
The authenticated record is a closed value, not a mapping: the `CIMP` and
profile digest that reach the worker come from it and there is no other route
by which they could arrive.

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

Nothing else crosses the transition: argv is the five-element tuple ruled in
§14.1, the environment is the two variables above, and the protocol is
descriptors 0, 1 and 2.

**Inherited descriptors are exactly `(0, 1, 2, 3)`**: stdin carries
coordinator→worker protocol, stdout carries worker→coordinator protocol,
stderr carries bounded diagnostics, and descriptor 3 carries the sealed,
root-authored profile object §14.1 rules. There are no dedicated protocol
descriptors in v1, and everything else is closed before the drop. Descriptor 3
is a governed exception rather than a return to ambient inheritance: root opens
the object itself, authenticates it before it is inheritable, and fixes the
number — no caller may name a descriptor, and a caller descriptor occupying a
governed number is replaced rather than honoured.

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
       ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py",
        "CINV-nnnnnn", "CIMP-nnnnnn", "<64 lowercase hex profile_digest>"),
       CLOSED_ENVIRONMENT)
```

The last two elements are taken by root from the launch record it has already
authenticated, for the reason §14.1.5 gives: the worker cannot check the
profile against itself, and must not read the coordinator-owned record.

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
the helper reads: `CINV`, `CIMP`, `profile_digest`, handoff root, profile
schema version, and the coordinator's commitment digest. The helper understands
that one record and nothing else. `profile_digest` replaced `oci_image_id` in
the §14.1 amendment: root commits to *bytes* and stays opaque to what they say,
so an image identity in the privileged parser would be a control root neither
needs nor may interpret.

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

### 14.1 Governed profile handoff — final ruling, amended 2026-08-13

**REQUIRED BUT NOT YET IMPLEMENTED.** Pass 3A resolves a `CIMP` into a governed
`ExecutionProfile` coordinator-side. This section rules how those bytes reach
the worker unaltered. Nothing below is built yet.

#### 14.1.1 Two withdrawn models, and what disproved them

Both were accepted in turn and then falsified empirically. They are recorded
because the reasons are the design.

**REJECTED — root-owned path freeze.** Root was to verify the coordinator's
`…/<CINV>/profile` and `chown` it to `root:root 0444` before dropping
privilege. Disproved: `unlink(2)` and `rename(2)` are authorised by write and
execute on the *containing directory*, not by the target's owner or mode, and
the target's ownership matters only under a sticky bit that `0555` does not
set. The coordinator **owns** `…/<CINV>/`, and `chmod(2)` requires ownership
rather than write permission — so it may always restore write access and
replace a root-owned file it cannot itself write.

**REJECTED — descriptor anchoring to the source inode.** Root was to open the
coordinator's profile, authenticate it, and pass that descriptor as FD 3.
Disproved: a descriptor pins an *inode*, never its *contents*. A coordinator
that retains an `O_RDWR` descriptor from before publication may write through
it afterwards; file mode is evaluated at `open(2)` only, so `0444` does not
revoke it, and a read-only open confers no exclusion on Linux. Reading through
root's own authenticated descriptor then returns substituted bytes.

The property required is **worker bytes == the exact bytes root authenticated**,
which is strictly stronger than *same inode*.

#### 14.1.2 Accepted — sealed, root-authored profile object

Root authenticates the coordinator's bytes and then **copies them into an
object only root has ever written, and which nobody can subsequently mutate**.

```
memfd_create("kyri-exec-profile", MFD_CLOEXEC | MFD_ALLOW_SEALING)
F_ADD_SEALS: F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL
```

Verified on this host (Linux 6.8, Python 3.12): after sealing, `write`,
`ftruncate` in both directions, adding a seal, and removing one are all
refused. A reopen through `/proc/self/fd/N` with `O_RDWR` **succeeds**, and is
harmless — the write and truncate through it are refused, because `F_SEAL_WRITE`
is enforced at the inode rather than per descriptor. `F_SEAL_SEAL` makes the
seal set itself final. The object has **no pathname**, so replacement is
meaningless; **no other handle exists**, so retained-writable-descriptor
mutation is impossible; and it is reclaimed with the process tree, so it has no
lifetime or cleanup question.

If a host cannot provide this exact contract, the transition **refuses**. There
is no fallback to a temporary file: a fallback would silently reinstate a model
this section rejects.

**The source profile stops being authority the moment the sealed copy passes
verification.** After that, path replacement, `chmod`, truncation, rewriting
through a retained descriptor, unlinking, and replacing the whole `<CINV>`
directory are all irrelevant. The handoff path remains only publication state
and cleanup evidence.

#### 14.1.3 Root stays policy-opaque

Root may read the raw bytes, hash them, compare the digest, copy them, and seal
them. Root **must not** parse `ExecutionProfile` or interpret `oci_image_id`,
mounts, resource policy, argv, or environment. To root the profile is an
authenticated opaque blob, which is what keeps §6's schema stop condition true:
the privileged parser understands one bounded record and nothing else.

#### 14.1.4 FD 3 lifecycle, and one trap

`PROFILE_FD = 3`, compiled in. `INHERITED_DESCRIPTORS = (0, 1, 2, 3)`.

This is an exception to stdio-only inheritance, not a return to ambient
inheritance: root opens the object itself, from a governed path, authenticates
it before it is inheritable, fixes the number, and passes it read-only. No
caller may name a descriptor number, and no caller descriptor survives because
it happened to occupy a governed one.

Two placement cases, both measured:

- **A caller pre-opens FD 3.** `dup2(sealed, 3)` replaces it atomically and
  clears `FD_CLOEXEC` on the new descriptor. The caller's object is closed by
  the same call. Verified.
- **The memfd is itself allocated as FD 3.** `dup2(3, 3)` is a POSIX no-op that
  returns success and **does not clear `FD_CLOEXEC`** — so the descriptor would
  be closed at `execve` and the worker would receive nothing. The transition
  must therefore clear the flag explicitly with `fcntl(3, F_SETFD, 0)` rather
  than relying on `dup2`, in both cases. Verified.

Order: create with `MFD_CLOEXEC`; copy; verify; seal; verify seals; place on
FD 3; clear `FD_CLOEXEC` explicitly; close every other non-stdio descriptor;
re-verify FD 3 is still the sealed object before dropping privilege.

#### 14.1.5 Authenticated worker context — five-element argv

The worker cannot verify `profile.cimp` or the digest against values taken from
the profile itself; that is circular. It cannot read the launch record either,
and must not — `…/execution/` is `cschott 0700` and coordinator-writable.

```
execve("/usr/bin/python3",
       ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py",
        "CINV-nnnnnn", "CIMP-nnnnnn", "<64 lowercase hex profile_digest>"),
       CLOSED_ENVIRONMENT)
```

Root takes both added values from the launch record it has already
authenticated and builds the argv itself, so the caller supplies neither. They
are short fixed-grammar tokens, visible in the exec tuple, needing no
environment variable and no second descriptor. The environment stays closed and
carries no `CIMP`, digest, path, descriptor number, or image identity.

#### 14.1.6 Worker validation

Exactly five argv elements — no optional three-element form. `CINV` and `CIMP`
by the existing grammars, `CIMP-000000` semantically refused, digest exactly 64
lowercase hex. Then, from **FD 3 only**: confirm the required seals via
`F_GET_SEALS`, bounded read, canonical parse, exact canonical round-trip,
construct the `ExecutionProfile`, recompute `fingerprint(profile).profile_digest`
and require equality with the argv digest, require `profile.cinv` and
`profile.cimp` to equal the argv values, and validate `oci_image_id` through the
existing governed contract. Only then may Podman argv be constructed.

The seal check is the strongest identity proof Linux actually offers here.
`fstat` on a memfd shows an anonymous inode on `tmpfs`, which distinguishes it
from a regular file but is not an unforgeable identity, and `/proc/self/fd`
naming is not a stable authority. **The cryptographic authority is the digest
comparison**, not the descriptor's provenance, and the ruling claims no more
than that.

#### 14.1.7 Ordering

Verified launch record → quota establish and read back → open the coordinator
profile `O_NOFOLLOW` → validate type, size, ancestry → hash the exact bytes read
from that descriptor → require the digest matches → create the memfd → copy →
rewind and verify the copy → apply the seals → read the seals back → place on
FD 3 → clear `FD_CLOEXEC` → reset the offset → close every descriptor outside
`(0, 1, 2, 3)` → re-verify FD 3 is sealed and readable → `setgroups` →
`setgid` → `setuid` → verify the drop is permanent → `no_new_privs` →
`execve` with the five-element argv. Root never reopens the profile path after
sealing, and nothing reaches Podman before the worker's checks complete.

#### 14.1.8 Threat matrix

| Attack | Prevented or detected by | Mechanism | Fails at |
|---|---|---|---|
| Path replaced after verification | sealed copy | no pathname is consulted after sealing | irrelevant |
| Retained writable source descriptor | sealed copy | bytes copied into a root-only object | irrelevant |
| Source truncated, rewritten, unlinked | sealed copy | source stops being authority | irrelevant |
| `<CINV>` directory `chmod`ed or replaced | sealed copy | same | irrelevant |
| Caller pre-opens FD 3 | transition | `dup2` replaces it atomically | before credential drop |
| Ambient descriptor leakage | transition | all but `(0,1,2,3)` closed | before credential drop |
| Sealed object mutated | kernel | `F_SEAL_WRITE`, enforced per inode | at `write`/`ftruncate` |
| Seals removed or weakened | kernel | `F_SEAL_SEAL` | at `F_ADD_SEALS` |
| Unsealed or wrong-type object on FD 3 | worker | `F_GET_SEALS` required set | before parse |
| `CIMP` substituted | worker | `profile.cimp` vs argv `CIMP` | before argv |
| `CINV` substituted | worker | `profile.cinv` vs argv `CINV` | before argv |
| Digest substituted | root, then worker | record digest vs source bytes; argv digest vs recomputed | before exec, then before argv |
| Image or any profile field substituted | root, then worker | digest covers all canonical bytes | before exec, then before argv |
| Non-canonical or malformed profile | worker | canonical round-trip | before argv |
| Wrong argv count | worker | exact five | before anything |

#### 14.1.9 Consequences

Launch record vNext stays **seven fields** — `oci_image_id` replaced by
`profile_digest`, and not reintroduced:

```
cinv · cimp · profile_digest · handoff_root · profile_schema_version
     · commitment_digest · lifecycle_state
```

Changed: the launch-record schema, the root helper, `INHERITED_DESCRIPTORS`,
and the worker exec tuple — therefore **installed generation 5**. Unchanged:
`ExecutionProfile` fields and schema version, payload schema version, the
coordinator↔worker protocol, and the `CIMP`/`CGEN` schemas.

§13 needs **no new row**: the profile is published at
`…/<CINV>/profile` as `cschott:cschott 0444`, exactly like `payload`, and is
never re-owned — the sealed copy, not the file's ownership, is what protects it.

> **Follow-up, unchanged and untouched.** Sealed transport closes the
> *execution-profile* authority TOCTOU only. `payload` and `package/` remain
> replaceable by the coordinator through the same directory-ownership route,
> and whether that matters before G6 is a separate hardening question this
> ruling deliberately does not answer.

### 14.2 Profile identity is not profile policy authority — ruling 2026-08-13

**REQUIRED BUT NOT YET IMPLEMENTED.** Generation 5 is installed, active and
accepted. Everything below is a ruling about what must be true before
`create_argv` becomes reachable; none of it is live, and nothing in this
section describes a control that exists today.

#### 14.2.1 What §14.1 proved, and what it did not

The sealed transport proves **profile identity**: the bytes the worker parses
are exactly the bytes the coordinator committed to, and no party — including a
coordinator holding a writable descriptor from before publication — can change
them afterwards. That property is real and is empirically tested.

It proves nothing whatever about **profile policy authority**: whether the
values inside those bytes were the governed ones. A profile is authenticated
against a digest the coordinator also authored, in a launch record the
coordinator also wrote. Authentication is a statement about *provenance and
integrity*, never about *content legitimacy*.

> **The rule.** Identity answers "are these the bytes that were committed?"
> Policy authority answers "was this value allowed to be what it is?" The
> sealed memfd answers the first. Only re-derivation from an independent
> governing source answers the second, and the two must never be argued for
> each other.

#### 14.2.2 Where the profile's values actually come from

`build_profile` accepts exactly one input — `ProfileBinding(cinv, admission)` —
and refuses any metadata. Within governed code the coordinator therefore
*cannot* vary a single security control: every one is a module constant in
`profile.py`. Five fields are not constants:

| Field | Source | Domain |
|---|---|---|
| `cinv` | the invocation being executed | invocation identity |
| `cimp` | `admission.cimp` | implementation authority |
| `oci_image_id` | `admission.oci_image_id` | implementation authority |
| `adapter_identity` | `admission.adapter_identity` | implementation authority |
| `payload_schema_version` | `admission.payload_schema_version` | implementation authority |

The authority root those come from is `root:cschott 0750` with `0440` records,
written only by offline operator tooling. **The coordinator reads it and cannot
write it**, which is what makes it an independent governing source.

The exposure is therefore precisely this: a **compromised** coordinator does not
have to call `build_profile` at all. It can write arbitrary canonical bytes to
`…/<CINV>/profile` and the matching digest into the launch record, and the
whole authenticated chain will faithfully deliver them.

#### 14.2.3 The dangerous set is exactly the argv-reaching fields

Of 32 profile fields, only **seven** reach `podman create` argv:
`cinv` (via the container name), `network`, `pids_limit`, `cpus`, `hostname`,
`tmpfs_options`, and `oci_image_id`. Memory, CPU quota/period, tmpfs size and
mode, execution UID and GID, mount topology and the capability set are
**compiled-in literals in `create_argv`** and are read from the profile only by
`verify_observed`.

That asymmetry decides the severity of every field:

- For a field that is a literal in argv and compared from the profile, a
  substituted value **cannot weaken the container**; it can only make the
  observed container disagree with the claimed profile, which fails closed as
  `execution_identity_mismatch`.
- For a field that reaches argv, the profile is simultaneously the *instruction*
  and the *expectation*. `verify_observed` compares the container against the
  same substituted profile and agrees. **There is no detection.** A profile
  carrying `network: "host"` produces a host-networked container that verifies
  as correct.

`cap_drop_all`, `privileged`, `host_network`, `host_pid`, `gpu`,
`timeout_seconds` and `grace_seconds` are today *inert*: they enter the digest
and are neither emitted into argv nor compared. They are declarations, not
controls — and the moment anything begins consuming them they inherit the
severity of the group above.

#### 14.2.4 Field authority matrix

`P` = producer, `G` = required governing authority, `V` = required verification
before `create_argv`. "Const" means the compiled-in value in `profile.py`.

| Field | P | Reaches argv | Required G | Required V | Implemented |
|---|---|---|---|---|---|
| `cinv` | invocation | yes (name) | invocation identity | equals argv `CINV` | **yes** |
| `cimp` | admission | no | implementation authority | equals argv `CIMP` | **yes** |
| `oci_image_id` | admission | **yes** | implementation authority | grammar + store presence (§27) | partial |
| `adapter_identity` | admission | no | implementation authority | equals `ADAPTER_IDENTITY` | no |
| `payload_schema_version` | admission | no | implementation authority | equals build constant | no |
| `profile_schema_version` | Const | no | compiled-in | equals `PROFILE_SCHEMA_VERSION` | partial |
| `network` | Const | **yes** | compiled-in | equals `NETWORK` (`"none"`) | **no** |
| `pids_limit` | Const | **yes** | compiled-in | equals `PIDS_LIMIT` | **no** |
| `cpus` | Const | **yes** | compiled-in | equals `CPUS` | **no** |
| `hostname` | Const | **yes** | compiled-in | equals `HOSTNAME` | **no** |
| `tmpfs_options` | Const | **yes** | compiled-in | equals `TMPFS_OPTIONS` as a set | **no** |
| `memory_bytes` | Const | no | compiled-in | equals constant | no |
| `memory_swap_bytes` | Const | no | compiled-in | equals constant | no |
| `cpu_quota_us` | Const | no | compiled-in | equals constant | no |
| `cpu_period_us` | Const | no | compiled-in | equals constant | no |
| `timeout_seconds` | Const | no | compiled-in | equals constant | no |
| `grace_seconds` | Const | no | compiled-in | equals constant | no |
| `read_only_rootfs` | Const | no (literal `--read-only`) | compiled-in | is `True` | no |
| `no_new_privileges` | Const | no (literal flag) | compiled-in | is `True` | no |
| `cap_drop_all` | Const | no (literal `ALL`) | compiled-in | is `True` | no |
| `dropped_capabilities` | Const | no | compiled-in | equals `("ALL",)` | no |
| `execution_uid` | Const | no (literal 1000) | compiled-in | equals `EXECUTION_UID` | no |
| `execution_gid` | Const | no (literal 1000) | compiled-in | equals `EXECUTION_GID` | no |
| `tmpfs_bytes` | Const | no (literal 16m) | compiled-in | equals constant | no |
| `tmpfs_mode` | Const | no (literal 1777) | compiled-in | equals constant | no |
| `mounts` | Const | no (built from sources) | compiled-in | equals the three governed destinations | no |
| `devices` | Const | no | compiled-in | is empty | no |
| `sockets` | Const | no | compiled-in | is empty | no |
| `privileged` | Const | no (inert) | compiled-in | is `False` | no |
| `host_network` | Const | no (inert) | compiled-in | is `False` | no |
| `host_pid` | Const | no (inert) | compiled-in | is `False` | no |
| `gpu` | Const | no (inert) | compiled-in | is `False` | no |

**Every "Const" row has the same remedy and it is cheap.** The worker already
installs `profile.py`; re-deriving those values needs no authority access, no
new descriptor, no schema change, and no privileged operation — it is an
equality check against constants the worker already holds. This is the required
amendment to §14.1.6: the worker's closed check list gains *policy
re-derivation* after identity binding and before `create_argv`.

`oci_image_id` needs **no** duplicate worker-side authority. The chain
`CIMP → admission → AuthorisedImplementation → profile` already derives it from
a root-owned namespace the coordinator cannot write, and the worker has neither
access to that namespace nor permission to read it (§7). Its residual is bounded
by something better: an image identity that was never loaded into the execution
identity's rootless store cannot run, and the store is not coordinator-writable.
A compromised coordinator can select any *admitted, present* implementation —
which is the coordinator's legitimate authority — and cannot conjure an image.
Adding a second image authority to the worker would be symmetry, not security.

#### 14.2.5 The `create_argv` gate invariant

```
create_argv MUST NOT be reachable unless, for the profile parsed from sealed
FD 3:

  1. fingerprint(profile).profile_digest == the argv profile digest, and
  2. profile.cinv == the argv CINV, and profile.cimp == the argv CIMP, and
  3. every compiled-in field equals this build's constant in profile.py, and
  4. oci_image_id is 64 lowercase hex and is present in the execution
     identity's rootless store, and
  5. adapter_identity and payload_schema_version equal this build's contract
     identities, and
  6. the published package tree and payload verify against commitments that
     crossed the privilege boundary under §14.1 protection, and
  7. the governed entrypoint likewise crossed under that protection.

Conditions 1-2 hold today. Conditions 3-7 do not.
```

Conditions 3 and 5 are a pure comparison. Condition 4 exists in §27 and must be
wired. Conditions 6 and 7 are the payload/package ruling below and are the only
ones that change a schema.

### 14.3 Payload and package — classification and ruling 2026-08-13

**REQUIRED BUT NOT YET IMPLEMENTED.**

#### 14.3.1 What they are, from the code

Neither is read by root, and neither is read by the worker. `validate_payload`
and `validate_package` run **coordinator-side before publication**; after that
the worker checks only type and mode in `verify_handoff` and derives three
pathname strings. The bytes are consumed by the **container**, at
`/kyri/package` and `/run/kyri/input/payload`, both `ro=true`.

Payload can never become argv or environment (§9, §10). Package content cannot
either — but the package **entrypoint string** becomes the final argv element
through `_container_script`, and that is the one part of either object with
argv reach.

#### 14.3.2 Classification

- **`payload` — authenticated invocation input, consumed only inside the
  sandbox.** Not execution authority. Substitution changes what the capability
  computed on; it cannot change the sandbox, the image, the identity, or any
  host access. The damage is to the *evidence chain* — Kyri would record that
  invocation X processed payload P when it processed P′ — not to containment.
- **`package/` — authenticated invocation input whose *entrypoint* is
  execution-adjacent.** Content substitution changes which code runs inside an
  unchanged sandbox: again an evidence-integrity failure, not an escape. The
  entrypoint string is different in kind, because it lands in argv.
- **Neither is execution authority.** Containment comes from the profile, which
  §14.1 protects; identity comes from `CIMP`/`CINV`, which the launch record and
  sealed profile bind.

#### 14.3.3 There is a gap here that is not about hardening at all

`create_argv` requires a `PackageBinding`, and **no code path gives the worker
one.** `validate_package` is coordinator-side and its result does not cross the
boundary. Before G6 the governed entrypoint and the package manifest digest must
reach the worker somehow — this is a missing contract, not merely a weak one,
and it is the reason condition 7 exists above.

#### 14.3.4 Alternatives considered

| Option | Prevents | Leaves | Cost |
|---|---|---|---|
| A. leave mutable, document containment | nothing | all substitution | none; but leaves the evidence chain unproven |
| B. root freezes the tree (`chown -R`) | replacement | nothing, *if it worked* | **rejected**: recursive privileged walk over a coordinator-supplied tree of up to 1,024 entries, with symlink and hardlink hazards, and it inherits §14.1.1's disproof — the coordinator owns the per-`CINV` directory and can `chmod` it back |
| C. descriptor anchoring | nothing | everything | **rejected**: §14.1.1 disproved it; a descriptor pins an inode, not its contents. Podman also needs a pathname for a bind source (§6) |
| D. copy into root-owned immutable storage | replacement | — | recursive privileged copy of ≤64 MiB per invocation, a new root-owned tree, and cleanup authority transferred to root. Disproportionate for non-authority data |
| E. sealed anonymous transport | replacement | — | **not applicable**: a bind-mount source must be a pathname; `/proc/self/fd/N` is rejected by §6 |
| F. digest commitment carried under §14.1 protection, verified by the worker | undetected substitution up to verification | substitution *after* verification | one profile schema field group and one worker-side verification pass; no privileged operation, no new descriptor, no cleanup authority |

#### 14.3.5 Ruling

**Option F, with a declared residual.** The governed profile gains
`payload_digest`, `package_digest`, and `package_entrypoint`. They then cross
the boundary under exactly the protection §14.1 already provides — sealed,
root-authored, digest-committed — and the worker verifies the published payload
and package tree against them, descriptor-safely and no-follow, immediately
before `create_argv`. This also supplies the missing entrypoint contract of
§14.3.3, so one change closes both.

**Declared residual, stated rather than engineered around:** a compromised
coordinator may still replace payload or package bytes *after* the worker
verifies them and before or while the container reads them. This is not closed,
because closing it costs a recursive privileged operation over caller-supplied
trees, and what it buys is protection of an evidence chain rather than of
containment. Mitigation is detection, not prevention: the same digests are
re-verified at collection, so a substitution becomes a classified integrity
failure rather than a silent one.

**Not chosen because it resembles the profile solution.** The profile needed
sealing because it *is* containment authority. Payload and package are not.

#### 14.3.6 Cross-`CINV` substitution

Material from `CINV-A` placed under `CINV-B` is today undetectable: the worker
checks type and mode only, and the paths are derived from the validated `CINV`,
so the wrong bytes at the right path are accepted. Under §14.3.5 it becomes
detectable, because the digests that must match arrive inside a profile whose
`cinv` is bound to the argv `CINV` and to the launch record. **The binding is
therefore digest-in-profile, not path-derivation.**

#### 14.3.7 Special files and the FIFO lesson

Every future verification read of payload or package members is performed by the
**unprivileged worker**, never by root — so the §14.1 FIFO defect cannot recur
at the privilege boundary. It can still hang the worker, so the same discipline
applies: `O_NOFOLLOW | O_NONBLOCK`, `fstat` before read, `S_ISREG` required,
bounded reads, `O_DIRECTORY` on every intermediate component, and refusal of
symlink, FIFO, socket, device node, directory substitution, and oversized
members. Hardlinks inside `package/` are harmless — the manifest digest covers
content, not link count.

#### 14.3.8 Cleanup and lifetime

Unchanged, deliberately. The coordinator continues to own publication and
cleanup of the per-`CINV` handoff; **no cleanup authority moves to root**, no
new privileged operation appears, and crash residue remains what §14 already
says it is: reported, never silently removed. Because no root-owned copy is
created, there is nothing new that a cleanup could delete and nothing new to
reconcile.

#### 14.3.9 Consequences

Changed: `ExecutionProfile` gains three fields → **profile schema version 2** →
new canonical bytes → new digests → **installed generation 6**. Unchanged: the
launch-record schema, the transition, root's opacity, `INHERITED_DESCRIPTORS`,
the worker exec tuple, the payload schema, the coordinator↔worker protocol, and
the `CIMP`/`CGEN` schemas. §13 needs no new row.

### 14.4 Pre-G6 attack matrix and trust flow

Status column: **held** = enforced today; **gap** = ruled above, not implemented;
**inert** = reachable only if a future change starts consuming the field.

| Attack | Authoritative source | Detecting component | Mechanism | Fails at | Status | Required work |
|---|---|---|---|---|---|---|
| Coordinator names an unadmitted image | implementation authority | coordinator | `authorise_implementation` derives from admission | before handoff | held | — |
| Compromised coordinator writes an arbitrary image ID into profile bytes | rootless store contents | worker | image presence (§27); store is not coordinator-writable | before `create` | gap | wire §27 check |
| Compromised coordinator sets `network: "host"` | `profile.NETWORK` | worker | re-derive against compiled-in constant | before `create_argv` | **gap** | §14.2.5 cond. 3 |
| Compromised coordinator raises `pids_limit` / `cpus` | `profile` constants | worker | same | before `create_argv` | **gap** | §14.2.5 cond. 3 |
| Compromised coordinator alters `tmpfs_options` (drops `noexec`) | `profile.TMPFS_OPTIONS` | worker | same | before `create_argv` | **gap** | §14.2.5 cond. 3 |
| Compromised coordinator alters `hostname` | `profile.HOSTNAME` | worker | same | before `create_argv` | gap | §14.2.5 cond. 3 |
| Compromised coordinator raises memory / changes UID / adds mounts or devices | `create_argv` literals | worker | value never reaches argv; `verify_observed` then disagrees | at verification | held | — |
| Compromised coordinator sets `privileged`/`host_pid`/`gpu` | — | — | field is inert: never emitted, never compared | nowhere | inert | keep inert or govern before use |
| Profile bytes substituted after publication | sealed memfd | root, then worker | §14.1 seal + digest | before exec, then before parse | held | — |
| Retained writable descriptor on the profile | sealed memfd | kernel | `F_SEAL_WRITE` per inode | at `write` | held | — |
| Cross-`CIMP` substitution | launch record + profile | worker | `profile.cimp` vs argv `CIMP` | before argv | held | — |
| Cross-`CINV` substitution of the profile | launch record + profile | root, then worker | record binds `CINV`; `profile.cinv` vs argv | before exec | held | — |
| Cross-`CINV` substitution of payload/package | profile digests | worker | digests carried in the profile | before `create_argv` | **gap** | §14.3.5 |
| Payload replaced after publication | profile `payload_digest` | worker | digest verification | before `create_argv` | **gap** | §14.3.5 |
| Payload replaced after worker verification | — | collector | re-verification at collection | at classification | **gap (residual)** | detection only, declared |
| Package member replaced after publication | profile `package_digest` | worker | manifest digest verification | before `create_argv` | **gap** | §14.3.5 |
| Package entrypoint substituted | profile `package_entrypoint` | worker | entrypoint crosses under §14.1 protection | before argv | **gap** | §14.3.3 |
| Parent-directory `chmod` + rename over payload/package | — | worker | digest at verification; residual after | before `create_argv` | **gap (residual)** | §14.3.5 |
| Symlink / FIFO / socket / device substitution in the handoff | worker read discipline | worker | `O_NOFOLLOW\|O_NONBLOCK`, `fstat`, `S_ISREG` | before read | partial | §14.3.7 |
| Package traversal escape | package contract | coordinator, then worker | validated at publication; re-checked at verification | before argv | partial | §14.3.7 |
| Stale handoff residue adopted as authority | handoff create-once | coordinator | existing `CINV` is a refusal | at publication | held | — |
| Unknown/unexpected profile control value | canonical round-trip | worker | exact field set + canonical re-serialisation | at parse | held | — |

**Trust flow, with the authority domains marked.**

```
  capability request                                   [invocation data]
        |
        v
  implementation authority  /var/lib/kyri/…            <== IDENTITY AUTHORITY
  root:cschott 0750, records 0440                          (coordinator reads,
  written only by offline operator tooling                   cannot write)
        |
        v
  resolve_implementation -> Admission
        |
        v
  authorise_implementation                             <== POLICY AUTHORITY
    build_profile(binding, metadata=None)                  enters here, and
    every control is a profile.py constant                 ONLY here today
        |
        v
  AuthorisedImplementation -> ExecutionProfile
        |
        v
  publish_handoff  ->  …/<CINV>/{profile,payload,package/,out/}
        |                                   ^
        |                                   |
        |                        [untrusted application data]
        |                        payload and package content
        v
  launch authorisation record (coordinator-written, create-once)
        |
        v
  root: authenticate record -> AuthenticatedLaunch     <== INTEGRITY ONLY
        authenticate profile bytes vs digest               root is opaque;
        copy into sealed memfd, place on FD 3               it proves identity,
        drop credentials, no_new_privs, execve              never policy
        |
        v
  worker: seals -> canonical parse -> round-trip
          fingerprint == argv digest
          profile.cinv/cimp == argv
          --------------------------------------------- <== POLICY AUTHORITY
          re-derive every constant field                     MUST re-enter here
          verify image presence                              (§14.2.5, NOT
          verify payload/package/entrypoint digests           IMPLEMENTED)
        |
        v
  create_argv  ->  podman create  ->  podman start
```

The diagram's point is the asymmetry: policy authority enters once, on the
coordinator side, and is currently never re-established after crossing a
boundary that explicitly does not carry it. §14.2.5 is the requirement that it
must be.

### 14.5 Worker-owned execution snapshot — ruling 2026-08-14

**REQUIRED BUT NOT YET IMPLEMENTED.** Pass 4A is source-complete; nothing below
exists. Generation 5 is installed and active and is unaffected by this section.

#### 14.5.1 What Pass 4A left open, measured rather than argued

Pass 4A verifies the payload and package commitments before `create_argv`. That
verification was then shown to close nothing, empirically: the gate was
satisfied, the coordinator restored write access to material it owns, replaced
the payload and the entrypoint, and the bind sources `create_argv` emits still
resolved to the mutated bytes.

```
bind: type=bind,src=/data/kyri/capability-handoff/CINV-000042/package,…
bind: type=bind,src=/data/kyri/capability-handoff/CINV-000042/payload,…
committed payload digest : 7dfecf7cff0e7f42
mounted  payload digest  : db9bf426931ed052
entrypoint Podman would run: import os / os.system("id")
```

Two independent reasons a second verification cannot fix this. Podman resolves
a **pathname** after any check the worker can make — §6 rejects
`/proc/self/fd/N` as a bind source, so there is no descriptor-anchored
alternative. And a bind mount is not a copy: the container shares the source
tree for its whole lifetime, so the window is not "verify → open" but
"verify → end of execution".

#### 14.5.2 Ruling: Option A, and why not the others

**Selected: the worker copies verified material into a snapshot it owns, under
ancestry the coordinator cannot mutate, and Podman binds only the snapshot.**

*Option C — accept the residual and detect only — is rejected.* Containment was
never the whole requirement. Kyri must be able to say that the material
presented to the container was the material the profile authenticated, and a
detection-only model can only say that it was, at one earlier instant.

*Option B — root-owned handoff ancestry — remains rejected.* It moves
publication and cleanup toward root and contradicts §14, where the coordinator
publishes and owns the handoff.

#### 14.5.3 Measured ancestry, and why a dedicated root is preferred

| Path | Owner | Mode | Usable |
|---|---|---|---|
| `/data`, `/data/kyri` | `cschott` | 0755 | no — coordinator renames any child |
| `…/capability-handoff/<CINV>/` | `cschott` | 0555 | no — the problem itself |
| `/data/kyri/capability` (worker `HOME`) | `kyri-capability` | 0750 | no — worker-owned, but its parent is coordinator-owned |
| `/data/kyri/capability-runtime/` | `cschott` | 0700 | no — worker has no access |
| `/run/user/999` | `kyri-capability` | 0700 | possible, rejected below |
| `/run` | `root:root` | 0755 | **yes — the only root-owned ancestry** |

**`/run/user/999` is assessed and not selected.** It measures better than the
earlier analysis assumed: it exists, is a 5.9 GiB tmpfs, is `uid=999 gid=987
mode=700`, and the user is **lingering** (`Linger=yes`), so it survives logout
and is recreated at boot by `systemd-logind`. It is rejected anyway, because it
is **rootless Podman's own runtime directory**: its lifecycle belongs to
`logind` rather than to Kyri provisioning, `podman` writes its own state there,
and a stale Kyri snapshot and a Podman runtime object would share a capacity
budget and a cleanup story that neither component owns. Coupling execution
material to another component's directory is how a lifetime question becomes
nobody's.

**Selected root: `/run/kyri/execution-material/`.**

| Object | Owner | Mode | Rationale |
|---|---|---|---|
| `/run` | `root:root` | 0755 | existing, tmpfs, `noexec` |
| `/run/kyri/` | `root:root` | 0755 | root-created, coordinator cannot write |
| `/run/kyri/execution-material/` | `root:kyri-capability` | 0770 | worker creates children; coordinator has no write, no read, and **no traverse** |
| `…/<CINV>/` | `kyri-capability:kyri-capability` | 0500 after materialisation | create-once, worker-owned |
| `…/<CINV>/payload` | `kyri-capability` | 0444 | worker-authored |
| `…/<CINV>/package/` | `kyri-capability` | 0500 | worker-authored |

`cschott` is in `cschott, adm, cdrom, dip, plugdev, lxd, sudo, docker`;
`kyri-capability` is in `kyri-capability` only, and group 987 has no
supplementary members. **The two share no group**, so `0770 root:kyri-capability`
admits the worker and excludes the coordinator. Mode `0770` rather than `0775`
is deliberate: the coordinator must not be able to traverse or enumerate.

`/run` is mounted `noexec`. That is harmless and mildly helpful: the container
runs `/usr/bin/python /kyri/package/<entrypoint>`, so package members are
**read** by the interpreter and never `execve`d.

#### 14.5.4 Authority split

- **Root/provisioning** creates `/run/kyri/` and `/run/kyri/execution-material/`
  and nothing else. It never enters a per-`CINV` directory, never reads payload
  or package, and gains no recursive parser or cleanup command.
- **The worker** creates its per-`CINV` snapshot after the credential drop,
  copies verified material into it, and owns its removal.
- **The coordinator** has no write, read, or traverse authority anywhere below
  the snapshot root.

#### 14.5.5 The snapshot algorithm

1. sealed profile verified (§14.1), governed policy re-derived, runtime
   contracts checked, image presence confirmed — all as Pass 4A already does;
2. the coordinator handoff payload and package verified against the profile
   commitments — Pass 4A, unchanged, and now an **ingestion** check;
3. `mkdir` the per-`CINV` snapshot **create-once** (`O_EXCL` semantics); an
   existing directory is a refusal, never a reuse or a silent delete;
4. write the payload into the snapshot **from the bytes already read and
   verified in step 2** — the source is never reopened;
5. copy the package tree descriptor-relatively, each member opened
   `O_NOFOLLOW | O_NONBLOCK` from the already-open source directory descriptor,
   type-checked, and written into a worker-created child;
6. **recompute both commitments over the snapshot** and require equality with
   the profile;
7. resolve `package_entrypoint` inside the snapshot and require an allowed
   regular member;
8. tighten the snapshot modes;
9. only then does collection succeed, and `create_argv` derives its bind
   sources from the snapshot root plus the validated `CINV`.

Step 6 is what makes step 5 safe: a package tree mutated *during* the copy
produces a snapshot whose commitment does not match, and the invocation is
refused. **No retry-until-stable loop.** One coherent attempt or a refusal —
a retry loop against an adversary that can always mutate again is a loop with
no defined end.

Files added, removed, or modified during the copy, a replaced directory, a
rename race, a symlink, a hard link, a FIFO, a socket, a device node, or an
unexpected directory all fail: the copy refuses the object types outright and
the recomputed commitment refuses everything else.

#### 14.5.6 What Podman binds

```
COORDINATOR HANDOFF        (cschott-owned, mutable, ingestion source only)
        |  verify commitments, then copy
        v
WORKER SNAPSHOT            /run/kyri/execution-material/<CINV>/
        |  recompute and require equality
        v
PODMAN BIND SOURCE         package/ and payload, worker-owned, coordinator
                           has no write, no traverse, no rename
```

`out/` is unchanged and stays in the handoff at `…/<CINV>/out/`: it is
worker-owned already, it is the one writable leaf, and the §34 XFS project
quota on `/data` is what bounds it. Moving it would move the quota story.

#### 14.5.7 Lifetime, cleanup, and residue

Created after the credential drop and before `podman create`; it must live
until the container is gone, because a bind mount keeps referencing it — so it
is **not** removed after `create`, and not after `start`. Removal happens with
the existing per-`CINV` cleanup, after output collection.

The worker removes its own snapshot. **No new root command, and the coordinator
never cleans this root.** A stale snapshot grants nothing: it is not execution
authority by existing, cannot be adopted for another `CINV`, cannot bypass a
commitment, and a create-once collision is a refusal rather than a delete. On
reboot `/run` is empty, which is correct — the snapshot is ephemeral execution
material. Durable evidence lives elsewhere; losing snapshots revokes no
implementation authority.

#### 14.5.8 Capacity

Bounded by contract, not by hope: package ≤ 64 MiB (1,024 entries), payload
≤ 2 MiB, so ≤ 66 MiB per invocation, and §23 caps live executions at **2
slots** — **≤ 132 MiB** of live snapshot at any time, against a 5.9 GiB
`/run`.

**The §34 XFS project quota does not protect `/run`.** It governs `/data` and
nothing else, and claiming otherwise would be a quota nobody enforces. The
governing bound here is the package/payload contract multiplied by the capacity
bound, plus create-once and worker cleanup. `/run` is shared with the rest of
the host, so **accumulated stale snapshots are the residual to watch**; if that
ever needs a hard limit, the mechanism is a dedicated `tmpfs` mount with a
`size=` option, ruled then rather than assumed now.

#### 14.5.9 Boot and provisioning classification

Created by **`systemd-tmpfiles`** (`/etc/tmpfiles.d/kyri-execution-material.conf`),
which needs no service, runs before anything Kyri does, and re-establishes the
root on every boot with the ruled owner and mode. systemd 255 is present and
`/etc/tmpfiles.d/` is in use.

This is a **generation-6 host prerequisite**, not a G4 amendment: G4 is closed
and accepted, nothing about it becomes untrue, and the new root is required
only by the runtime this generation installs. It is an operator step in the
runbook, applied with the generation-6 installation and not before.

#### 14.5.10 Invariance

No change to `/usr/libexec/kyri-exec-transition`, `/usr/libexec/kyri-exec-worker.py`,
`kyri_exec_transition.py`, `kyri_exec_transition_action.py`, `PROFILE_FD`, the
seal contract, the five-element argv, root's opacity, or the quota/drop/
`no_new_privs` ordering. The snapshot is worker-side, after the credential
drop. No new `ExecutionProfile` field, no launch-record change, no payload
schema change, no protocol change: the Pass 4A commitments are exactly what the
snapshot is verified against.

#### 14.5.11 Attack matrix

| Attack | Source | Prevented/detected by | Mechanism | Fails at | Residual |
|---|---|---|---|---|---|
| Retained writable payload descriptor | coordinator | snapshot | snapshot bytes are worker-authored; no coordinator handle ever existed | irrelevant | none |
| Retained writable package member descriptor | coordinator | snapshot | same | irrelevant | none |
| `chmod` the handoff directory | coordinator | snapshot | handoff is ingestion only after copy | irrelevant | none |
| Payload rename/replace after verification | coordinator | snapshot | Podman binds the snapshot | irrelevant | none |
| Package directory replaced after verification | coordinator | snapshot | same | irrelevant | none |
| Mutation **during** the copy | coordinator | worker | commitment recomputed over the snapshot | before `create_argv` | invocation refused, no retry |
| Mutation **after** the copy | coordinator | snapshot | coordinator cannot reach the snapshot | irrelevant | none |
| Mutation during container execution | coordinator | snapshot | bind source is worker-owned | irrelevant | none |
| Cross-`CINV` substitution | coordinator | worker | commitments come from a profile bound to the argv `CINV` | before `create_argv` | none |
| Snapshot collision | crash residue | worker | create-once refusal, never adoption or delete | before copy | operator disposition |
| Stale snapshot reuse | crash residue | worker | existence is not authority; commitments still required | before `create_argv` | none |
| Symlink or special file introduced during copy | coordinator | worker | type check per member, `O_NOFOLLOW`, `O_NONBLOCK` | during copy | none |
| Coordinator traverses the snapshot | coordinator | kernel | `0770 root:kyri-capability`, no shared group | at `open` | none |
| Coordinator `chmod`/renames the snapshot parent | coordinator | kernel | parent is `root:root`; ownership is required to `chmod` | at `chmod` | none |
| `/run` exhaustion | coordinator or accumulation | capacity + contract | ≤66 MiB × 2 slots, plus cleanup | at allocation | **stale accumulation** |
| Interactive `cschott` with `sudo`/`docker` | operator | — | out of scope | — | **operator is trusted; see below** |

**One scope statement, stated rather than implied.** `cschott` is in `sudo` and
`docker`, so the *interactive operator identity* is root-equivalent and no
filesystem ownership defends against it. That has always been true and is not
what this boundary is for: the threat model is the **coordinator process**,
which holds one `NOPASSWD` grant over one command with one argument and cannot
`chmod`, `chown`, or write outside its own trees. Option A closes the race
against that actor completely.

#### 14.5.12 The Pass 4B guarantee, exactly

> The bytes and tree Podman mounts are a **worker-owned snapshot**, created from
> invocation material whose commitments match the authenticated
> `ExecutionProfile`, under ancestry the coordinator can neither write,
> traverse, rename, nor `chmod`.

And the distinction that must survive into the implementation:

- **the source handoff may remain mutable** — it is coordinator-owned
  publication material and stays that way; and
- **the container-consumed snapshot is not coordinator-mutable** — which is the
  property Pass 4A could not provide and this ruling exists to add.

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
