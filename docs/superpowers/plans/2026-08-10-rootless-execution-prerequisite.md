# Rootless Execution Prerequisite Design (ENG-0005)

**Status:** Proposed — not accepted. The host changes this document anticipated
were subsequently provisioned and validated on `schai` on 2026-08-11; see §22.

> **Documentation and read-only discovery only. This document authorises no
> host change.** No package is installed, no AppArmor policy altered, no sysctl
> changed, no account created, no subuid/subgid range assigned, no service
> defined, and no adapter implemented. Every finding below was obtained by
> read-only inspection or by `apt-get --simulate`.

Determines the smallest safe host prerequisite set for a future rootless OCI
adapter satisfying §10.2 of the
[ENG-0005 Capability Runtime design](../specs/2026-08-10-capability-runtime-design.md).

## 1. Why rootless

Rootful Docker was rejected as the production execution boundary. The container
itself enforces useful isolation — a read-only probe confirmed `--network none`
yields zero interfaces and no DNS, `--read-only` denies rootfs writes, and
`--user 65534` runs unprivileged — but the coordinator would need Docker daemon
access, and `docker` group membership is **root-equivalent on the host**. A
compromise of the Capability Runtime would become host root through the daemon.

`systemd-run --user` was rejected on measured evidence: it **accepted**
`PrivateNetwork=yes` and `ProtectSystem=strict` and **enforced neither** — the
transient unit saw all seven host interfaces, resolved DNS, and wrote into the
repository. Configuration acceptance is not enforcement.

## 2. Host evidence

Gathered on `schai`, 2026-08-10, read-only.

| Item | Observed |
|---|---|
| OS / kernel | Ubuntu 24.04.4 LTS, `6.8.0-136-generic`, x86_64 |
| Namespaces | all present: `cgroup ipc mnt net pid user uts time` |
| `kernel.apparmor_restrict_unprivileged_userns` | **1** |
| `kernel.unprivileged_userns_clone` | 1 |
| `user.max_user_namespaces` | 240298 |
| `unshare --user --map-root-user` | **fails, EPERM** on `/proc/self/uid_map` |
| cgroup | **v2 unified**; controllers `cpuset cpu io memory hugetlb pids rdma misc` |
| seccomp | `CONFIG_SECCOMP=y` |
| AppArmor / SELinux | AppArmor **enabled** (`apparmor 4.0.1-0ubuntu0.24.04.7`); SELinux absent |
| Podman, bwrap, firejail, crun | **absent** |
| `newuidmap` / `newgidmap` | **absent** (`uidmap` not installed) |
| runc | **1.3.6** present |
| `/etc/subuid`, `/etc/subgid` | one entry each: `cschott:100000:65536` |
| `/data` | 500 G, 33 G used, owned `cschott` |

## 3. B1 — the exact blocker, and the narrow path around it

**The blocker is not the sysctl in isolation.** Under
`apparmor_restrict_unprivileged_userns=1`, an **unconfined** program cannot
create an unprivileged user namespace. A program covered by an AppArmor profile
that grants the `userns` permission still can.

**Ubuntu already ships that profile for Podman.** Present on this host, from the
`apparmor` package, with Podman not installed:

```
# /etc/apparmor.d/podman
# This profile allows everything and only exists to give the
# application a name instead of having the label "unconfined"
profile podman /usr/bin/podman flags=(unconfined) {
  userns,
  include if exists <local/podman>
}
```

and the companion profile a process transitions into when it creates one:

```
# /etc/apparmor.d/unprivileged_userns
profile unprivileged_userns {
     audit deny capability,
     audit deny change_profile,
     allow network, signal, dbus, file rwlkm /**, unix, mqueue, ptrace, userns,
     allow pix /** -> &unprivileged_userns,
}
```

**Answers to B1:**

1. **Does rootless Podman require unrestricted generic unprivileged user
   namespaces?** **No.** It requires that *Podman* be permitted, which the
   shipped per-program profile already does.
2. **Is there a narrower supported path?** **Yes — and it is already present
   and is the Ubuntu-supported mechanism.** Ubuntu's security documentation
   states: *"AppArmor can deny unprivileged applications the use of user
   namespaces… Applications requiring unprivileged namespaces must be
   explicitly allowed by their AppArmor profile."*
3. **Does Podman packaging supply AppArmor integration?** The profile ships in
   Ubuntu's `apparmor` package rather than in `podman`, and is present on this
   host today.
4. **Can a dedicated service account be granted only the required authority?**
   Yes — via its own subuid/subgid ranges. The namespace permission is
   per-program, the identity mapping is per-account, and the two compose.
5. **Without globally weakening user namespaces?** **Yes.** `sysctl` stays at
   `1`; no global relaxation is proposed.

**Honest qualification, and it matters.** Both shipped profiles are
**permissive**. The `podman` profile is `flags=(unconfined)` and "allows
everything"; `unprivileged_userns` allows `file rwlkm /**`, `network`, and
`ptrace`, denying only `capability` and `change_profile`. **AppArmor here is a
naming mechanism that satisfies the restriction — it is not the confinement.**
The actual isolation must come from the container configuration: namespaces,
`--network none`, dropped capabilities, read-only mounts, and limits. Anyone
reading "AppArmor profile" as "sandboxed" would be wrong.

## 4. B2 — package requirements

From `apt-get install --simulate --no-install-recommends podman uidmap`
(simulation only, nothing installed) — **7 packages**:

| Package | Version | Class |
|---|---|---|
| `podman` | 4.9.3+ds1-1ubuntu0.2 | **required** |
| `uidmap` | 1:4.13+dfsg1-4ubuntu3.2 | **required** — provides `newuidmap`/`newgidmap`, both absent today |
| `conmon` | 2.1.10+ds1-1build2 | **required** — container monitor |
| `libsubid4` | 1:4.13+dfsg1-4ubuntu3.2 | pulled dependency |
| `golang-github-containers-common` | 0.57.4+ds1-2ubuntu0.2 | pulled dependency |
| `golang-github-containers-image` | 5.29.2-2 | pulled dependency |
| `containernetworking-plugins` | 1.1.1+ds1-3ubuntu0.24.04.3 | pulled dependency |

With recommends the set grows to **15**, adding `netavark`, `aardvark-dns`,
`slirp4netns`, `libslirp0`, `fuse-overlayfs`, `catatonit`.

**Unnecessary for ENG-0005:**

- `slirp4netns`, `pasta`, `netavark`, `aardvark-dns` — **network plumbing, and
  ENG-0005 denies networking.** Not installing them removes the machinery that
  would give a container connectivity, which is a security improvement, not a
  gap.
- `fuse-overlayfs` — recommended for storage performance; without it rootless
  Podman uses the `vfs` driver, which is slower and more space-hungry but
  correct. **Evaluate on measurement, not by default.**
- `crun` — not required; `runc 1.3.6` is already present and is Podman 4.9.3's
  default on noble.

**`--no-install-recommends` is the recommended posture**, precisely because the
recommends are mostly networking.

## 5. B3 — dedicated identity

**Proposed:** a dedicated system account, repository-consistent name
**`kyri-capability`**.

| Property | Design |
|---|---|
| UID/GID | system range, allocated at provisioning; dedicated primary group |
| Home | `/data/kyri/capability` — not `/home`, keeping runtime state on the platform volume |
| Runtime dir | `XDG_RUNTIME_DIR` under `/run/user/<uid>`, requiring lingering |
| subuid/subgid | one dedicated 65536 range, **not** overlapping `cschott:100000:65536` |
| Login | disabled — no password, no SSH key |
| Shell | `/usr/sbin/nologin` |
| Lingering | `loginctl enable-linger` required so the user manager exists without a session |
| Fabric store | **read-only** access to evidence only |
| Trust store | **none** — no read, no write |
| Capability Runtime store | **no direct access** — the coordinator writes evidence, not the execution identity |
| Staging | read-only access to the content-addressed staging area |

**Principle:** the execution identity receives the minimum for one invocation —
the verified artefact and its payload — and **no write authority to the Fabric
store, the Trust store, or the evidence store.** A capability that could write
evidence could make a refused execution look governed.

**Open design question for review:** whether the *coordinator* also runs as
`kyri-capability` or as a separate identity that owns the evidence store and
merely launches containers as the execution identity. The two-identity split is
stronger — evidence stays unwritable by anything the capability can reach — and
is the recommendation.

## 6. B4 — rootless storage

`/data` is a 500 G volume with 468 G free, already the platform's persistent
location (`/data/kyri`, `/data/ai`, `/data/docker`). OS root capacity must not
absorb container images.

| Item | Location |
|---|---|
| `graphroot` | `/data/kyri/capability/storage` |
| `runroot` | `/run/user/<uid>/containers` (tmpfs, cleared on reboot) |
| Images | inside `graphroot`; **pre-provisioned**, never pulled during an invocation |
| Staging (verified artefacts) | `/data/kyri/capability/staging`, mode `0700`, coordinator-owned |
| Per-invocation work | container-internal `tmpfs`, discarded on exit |
| Output | a bounded, explicitly mounted directory, only where an invocation requires one |
| Cleanup | coordinator-owned; staging entries are content-addressed and reusable, and **residue is reported, never silently cleaned** |
| Quotas | a filesystem quota or a size cap on `graphroot` and `staging` — recommended, sized at provisioning |

## 7. B5 — networking

**Default: `--network none`.**

- Podman rootless with `--network none` places the container in a **new empty
  network namespace** — loopback only, no veth, no route to the host.
- With no `slirp4netns`, `pasta`, `netavark`, or `aardvark-dns` installed,
  there is **no user-space networking helper on the host to provide
  connectivity even if one were requested** — defence in depth, from absence.
- **DNS** is unavailable: no resolver is reachable and no `aardvark-dns` exists.
- **Host networking cannot be selected by capability input.** Network mode is a
  coordinator-constructed argument. Package metadata, payload, and capability
  code never reach the container-creation arguments (ENG-0005 §10.1: structured
  input, no command construction).
- **Network mode is coordinator-owned, never package-owned** — a normative
  requirement of any adapter specification built on this document.

Network-enabled capabilities are **out of scope** and would require their own
authorisation, transport design, and egress policy.

## 8. B6 — filesystem and mount policy

**The container receives, and nothing else:**

1. the verified content-addressed artefact, **read-only**;
2. a controlled working directory (`tmpfs`, container-internal);
3. explicitly authorised read-only inputs, when an invocation declares them;
4. a bounded writable output location, **only if** the invocation requires one.

**It must never receive:** the repository root · the Fabric store · the Trust
store · the Capability Runtime evidence store · any Docker or Podman socket ·
host `/` · any home directory · SSH material · host secrets.

Root filesystem **read-only**; writable areas are `tmpfs` with explicit size
caps. `nodev`, `nosuid`, and `noexec` are appropriate on every writable mount —
noting that the artefact mount cannot be `noexec` for adapters that execute it
directly, which is itself an argument for an interpreter-based adapter where
the artefact is data to a pre-approved interpreter rather than an executable.

## 9. B7 — container privilege profile

| Control | Target |
|---|---|
| Container UID/GID | non-root inside the container, mapped into the dedicated subuid range |
| Capabilities | `--cap-drop=ALL`, none added |
| Privilege escalation | `--security-opt no-new-privileges` |
| Root filesystem | `--read-only` |
| Writable space | `--tmpfs` with explicit size, `nodev,nosuid` |
| PIDs | `--pids-limit` (small, e.g. 64) |
| Memory | `--memory` with `--memory-swap` equal, so swap cannot evade the cap |
| CPU | `--cpus` |
| Output | captured and byte-bounded by the coordinator |
| Devices | **none** — `--device` never used |
| GPU | **not authorised.** The Tesla P4's presence authorises nothing; GPU access requires device passthrough, breaks the no-devices default, and needs separate authorisation |
| Timeout | coordinator-enforced deadline plus `--timeout` |

## 10. B8 — seccomp and AppArmor

- **Podman default seccomp:** Podman applies a default seccomp profile blocking
  a large set of syscalls. That default is the starting point, not the design.
- **A narrower ENG-0005 profile is justifiable** — capability workloads need far
  less than a general container — but it is **premature**: writing one before a
  concrete adapter exists means guessing the syscall surface. **Deferred, with
  the default retained meanwhile.**
- **AppArmor for rootless containers on Ubuntu:** as §3 records, the shipped
  profiles are permissive naming devices. A dedicated confining profile for the
  Capability Runtime should eventually exist; it is not created here.
- **No profile is created by this document.**

## 11. B9 — OCI image authority

The coordinator MUST NOT pull an image whose name comes from capability
metadata. Design targets:

- an **operator-approved image set**, enumerated in configuration;
- images referenced by **digest** (`image@sha256:…`), never by tag;
- **no `latest`**, ever;
- **no capability-selected registry**;
- **no network pull during an invocation** — images are pre-provisioned into
  `graphroot`, and invocation-time pulls are refused;
- an unknown or unpinned image **refuses**.

**This is separate from the capability artefact digest.** The image is the
approved execution environment; the artefact is the governed capability. Two
different trust decisions, two different digests, and conflating them would let
an approved image vouch for unapproved code.

## 12. B10 — TOCTOU under rootless Podman

The requirement is unchanged: **verified bytes == executed bytes**, with no
attacker-mutable path re-opened after verification.

"Open once and execute from the same descriptor" is **not achievable directly**
with either Docker or Podman: the container engine resolves bind-mount sources
itself, so a coordinator's `/proc/self/fd/N` is not meaningful to it.

**The design that does hold:**

1. coordinator opens the artefact **once**;
2. computes `sha256` **from that descriptor**;
3. compares against the manifest digest; mismatch → refuse;
4. copies bytes **from that same descriptor** into
   `/data/kyri/capability/staging/sha256-<hex>/artifact`, created atomically
   (temporary + `rename`) with mode `0400`, in a directory mode `0700` owned by
   the coordinator identity and **never writable by the execution identity**;
5. re-verifies the staged copy's digest after `rename`;
6. bind-mounts the staged path **read-only** into the container.

| Concern | Behaviour |
|---|---|
| Ownership | coordinator identity; execution identity has read-only access |
| Permissions | `0700` directory, `0400` file |
| Naming | derived from the verified digest — content-addressed |
| Atomic creation | temporary + `rename`; a pre-existing temporary is preserved and reported, never truncated |
| Collision | same digest, same bytes → reuse; same digest, different bytes → **refuse** and report |
| Mount | read-only |
| Cleanup | coordinator-owned, explicit; staging is reusable |
| Residue | reported by validation, **never silently removed** |

Because the staged path is never writable by the execution identity or by
whoever controls the original artefact directory, the window the requirement
targets is closed.

## 13. B11 — coordinator-to-Podman authority

| Mechanism | Persistent authority surface | Assessment |
|---|---|---|
| **Direct rootless CLI invocation** (`podman` as the execution identity, argv array) | **none persistent** — no socket, no daemon, no listener | **Recommended** |
| Rootless Podman socket / REST API | a live API socket for the account's lifetime; anything reaching it controls containers | **Rejected** unless a specific need appears |
| Dedicated user service | a long-running unit and its lifecycle, contradicting ENG-0005 §20 (no daemon) | **Rejected** |
| System-wide Podman service | root-adjacent; reintroduces the rejected Docker property | **Rejected** |

**Recommendation: direct rootless CLI invocation, no socket, no API, nothing
listening.** Podman is daemonless by design, which is the property Docker
lacked. **No unrestricted Podman API socket is exposed to any user or
process.**

## 14. B12 — lifecycle (containment only, not Health)

| Concern | Design |
|---|---|
| Naming | one container per invocation, named from the invocation record identity — unique, traceable, non-colliding |
| Startup | coordinator constructs an argv array; capability input never reaches it |
| Timeout | coordinator deadline is authoritative; the container gets its own as defence in depth |
| Termination | `SIGTERM`, bounded grace, then `SIGKILL` |
| Exit classification | exit code and termination reason mapped to the specification's outcome classes (`completed`, `adapter-error`, `timeout`, `interrupted`) |
| Orphans | a container outliving its coordinator is detected by name at inspection and **reported** |
| Residue | reported, never silently cleaned |
| Cleanup | `--rm` for the normal path; explicit operator action for residue |
| Reboot | `runroot` on tmpfs clears; staging on `/data` survives and stays valid because it is content-addressed |

**This is invocation containment, not Health.** Nothing here derives a health
state, restarts anything, or influences selection. Exit information is recorded
as evidence of one invocation and read by no selection path.

## 15. B13 — observability

**Captured:** exit code · termination reason · `stdout`/`stderr` **bounded and
truncated with the truncation recorded** · start and end timestamps ·
resource-limit termination (OOM, CPU, PID cap) · container runtime error.

**Not captured:** unrestricted logs · full payloads or results (digests and
references only) · anything derived from secret material. Redaction applies to
every reason string, consistent with the released "no full prompts or responses
by default" rule.

## 16. B14 — rollback plan (not executed)

For every prerequisite that would eventually be required:

| Change | Rollback |
|---|---|
| Packages (7) | `apt-get purge podman uidmap conmon` and autoremove the pulled dependencies; `runc` predates this work and stays |
| subuid/subgid range | remove the `kyri-capability` lines from `/etc/subuid` and `/etc/subgid` |
| Dedicated account | `loginctl disable-linger`, then remove the user and its group |
| Storage | remove `/data/kyri/capability/{storage,staging}` after evidence is archived |
| Lingering / user manager | `loginctl disable-linger`; no unit files are created, so none is removed |
| AppArmor | **nothing to roll back** — no profile is added or modified; the shipped ones are untouched |
| sysctl | **nothing to roll back** — no sysctl is changed |
| Docker | untouched throughout; not removed, not altered |

The rollback surface is small precisely because the design changes no global
security setting.

## 17. B15 — comparison with the rejected rootful Docker design

| Property | Rootful Docker | Rootless Podman |
|---|---|---|
| Coordinator needs daemon access | **yes** — `docker` group | **no** |
| `docker`-group ≈ host root | **yes** | n/a |
| Daemon running as root | **yes** | **no daemon at all** |
| Persistent socket | **yes** | **none** |
| Container UID maps to host root | root unless remapped | maps into an unprivileged subuid range |
| Network denial | proven effective | expected effective, plus helpers absent |
| Filesystem isolation | proven effective | equivalent |
| Global security change required | none | **none** |
| **Compromise → host root via engine authority** | **YES** | **eliminated** |

**Does rootless Podman eliminate `Capability Runtime compromise → host root
through container daemon authority`? Yes — that specific path is eliminated.**
There is no daemon, no socket, and no privileged group; the coordinator's
authority is its own unprivileged account.

**What it does not eliminate, stated plainly:** kernel attack surface. Rootless
containers rely on user namespaces, and a kernel or `newuidmap` vulnerability
remains an escalation path — which is exactly what
`apparmor_restrict_unprivileged_userns` exists to reduce, and this design keeps
that restriction in force for everything except Podman. It also does not make
the permissive shipped AppArmor profiles into confinement (§3), and it does not
protect against a capability abusing whatever the invocation legitimately gives
it.

## 18. Classification

### **POD-B — rootless Podman is feasible but requires a narrowly scoped host security exception**

**Feasible:** the kernel supports it, cgroup v2 is available, the AppArmor
mechanism that permits Podman's user namespaces is **already shipped and
present**, no sysctl needs relaxing, and the package set is 7 with
`--no-install-recommends`.

**Not POD-A**, because host changes are still required and one of them is a
security grant: a dedicated account receiving subuid/subgid ranges and, through
the shipped profile, the ability to create user namespaces that unconfined
programs on this host cannot. That is narrow and per-account — but it is an
exception, and calling it none would understate it.

**Not POD-C:** nothing global is weakened; `apparmor_restrict_unprivileged_userns`
stays at `1`.

**Not POD-D:** the evidence is sufficient to decide. What remains is
provisioning, not discovery.

## 19. Host changes that would eventually be required

1. install 7 packages with `--no-install-recommends`;
2. create the `kyri-capability` system account (nologin, no password);
3. assign it dedicated, non-overlapping subuid/subgid ranges;
4. enable lingering for its user manager;
5. create `/data/kyri/capability/{storage,staging}` with restrictive ownership;
6. pre-provision the digest-pinned approved image set;
7. optionally, a filesystem quota on the storage root.

## 20. Host changes explicitly NOT required

- **no sysctl change** — `apparmor_restrict_unprivileged_userns` stays `1`;
- **no AppArmor policy change** — the shipped profiles are used as-is;
- **no global user-namespace relaxation**;
- **no change to the existing `cschott` subuid/subgid entry**;
- **no Docker change and no Docker removal**;
- **no firewall change**;
- **no system service**;
- **no GPU or device configuration**.

## 21. Remaining security risks

1. **The shipped AppArmor profiles are permissive**, not confining (§3). A
   dedicated confining profile should follow.
2. **Kernel attack surface via user namespaces** remains the principal
   escalation path (§17).
3. **`newuidmap`/`newgidmap` are setuid** — historically a source of
   vulnerabilities, and the one privileged component this design depends on.
4. **The default seccomp profile is broad**; a narrower one is deferred.
5. **The image set is a second trust decision** (§11); an unreviewed approved
   image undermines everything downstream of it.
6. **Coordinator/execution identity separation is a recommendation, not yet a
   ruling** (§5).

## 22. Track-B provisioning outcome (2026-08-11)

**Track B is provisioned.** The host changes in §19 were applied and an
enforcement battery was executed against the resulting sandbox. Sandbox
isolation is proven; **no adapter exists**, so capability execution through the
Kyri Capability Runtime remains unavailable.

Provisioned: podman 4.9.3 with `uidmap`; the `kyri-capability` system account
(uid 999, `nologin`); subuid/subgid `200000:65536`; lingering; graphroot at
`/data/kyri/capability/.local/share/containers/storage`; one digest-pinned
image. Rootful `podman.socket` and `podman.service` are **masked and inactive**
and no Podman listener exists, satisfying §13's no-daemon, no-API requirement.
As §20 required, no sysctl and no AppArmor policy changed —
`apparmor_restrict_unprivileged_userns` remains `1`.

Eighteen isolation domains were exercised. Seventeen passed on the first
battery; the PID-limit probe was initially **inconclusive** because it exhausted
the PID budget and then needed a fork to report, so its diagnostics destroyed
themselves. A corrected probe read the cgroup leaf from the host via
`/proc/<live-pid>/cgroup` and closed the gate.

| Control | Evidence |
|---|---|
| Rootless identity | container uid 0 → host uid 999; `uid_map 1 200000 65536` |
| Network | `--network none`; loopback only, no route, no DNS, no outbound |
| Filesystem | repository, Fabric, Trust, evidence store, canonical staging, and both sockets absent from the namespace |
| Root filesystem | read-only; `/tmp` a bounded tmpfs, `noexec` proven (rc=126) |
| Privilege | `CapBnd` all-zero, `NoNewPrivs=1`, seccomp filter active |
| Devices/GPU | no nvidia, no block devices, no sockets |
| Memory | `memory.max=268435456`; OOM kill observed (137) |
| CPU | `cpu.max 50000 100000`; measured 1.539 s CPU over 3 s wall ≈ 0.51 cores |
| PIDs | `pids.max=64`, `pids.peak=64`, `pids.events: max 1` |
| Environment | planted secret absent; four-variable container environment |

The PID result rests on the kernel's own counters. Sampling alone peaked at 63
and would have left the gate inconclusive; `pids.peak` is race-immune and
recorded the boundary, and `pids.events` counts denials the kernel actually
refused.

**A repository-access contract violation was found and corrected.** The
execution identity could read `/opt/schott-platform`, because the directory was
mode `0755` — world traverse, not a group or ACL grant. It is now `0750
cschott:cschott`. The two-identity model requires the execution identity to lack
repository access in its own right, rather than relying on an adapter's promise
never to run capability code outside a container.

**Also recorded, not solved:** `/data` is XFS mounted `noquota`, so disk-quota
enforcement is unavailable without a storage or mount architecture change. This
is not an isolation blocker — cgroup memory, PID, and CPU controls do not bound
disk, so §23-D applies instead.

Track A remains non-executing, ENG-0005 is **not** complete, ENG-0006 has not
begun, no subjects are seeded, and no TrustGateway cutover has occurred. The
next step is a first-adapter specification, not an implementation.

## 23. Mandatory first-adapter requirements from Track-B evidence

These are normative inputs to the first adapter specification.

### A — output directories are hostile

A container-created symlink persisted into the shared work directory as
`link -> /etc/shadow`. Inside the container it resolved to the image's own
`/etc/shadow`, which is harmless. On the host it resolved to the **real**
`/etc/shadow` (`root:shadow`, mode `0640`), so a privileged host reader
following it — a `sudo cat`, a glob copy, an adapter harvesting outputs — would
read it. The unprivileged container wrote a symlink that weaponises a privileged
reader.

**Container output is untrusted filesystem input to the coordinator.** The
output collector must walk descriptor-relatively; never follow symlinks; use
no-follow semantics throughout; accept regular files only by default; reject
symlinks, FIFOs, sockets, and devices; enforce ownership, type, and link rules;
bound output file count, individual size, and aggregate size; stay beneath the
approved output root; read only through verified descriptors; and **never
privileged-glob-copy an output directory**.

`tools/common/trusted_source.py` already implements the required primitive —
`O_NOFOLLOW` with component-by-component `openat` against a directory
descriptor. The collector should extend it rather than introduce a second
mechanism.

### B — lifecycle state precedes ExitCode

A container whose configured command did not exist reported state `Created`
with `ExitCode = 0` — a failed launch indistinguishable from success by exit
code alone. **ExitCode is not execution-success authority.** Classification must
evaluate, in order: container creation, workload start, runtime/container
lifecycle state, termination mode, **ExitCode only after the workload is proven
to have started**, then bounded output evidence. `Created` or any never-started
state is a launch failure regardless of the reported exit code.

### C — canonical staging requires a per-invocation handoff

The execution identity has no host access to canonical A4 staging, and must not
be granted persistent access to it. The adapter must introduce a per-invocation
handoff proving `canonical staged digest == handoff digest == bytes mounted into
the container`, derived only from the verified staged object with no
source-path reopen, immutable from the execution identity, in an
invocation-specific namespace exposing no unrelated artefact, with a bounded
lifetime, residue reporting, and descriptor-safe cleanup.

### D — disk exhaustion is unbounded

Because `/data` is mounted `noquota` (§22), first-adapter and runtime hardening
must bound invocation work and output size, handoff size, retained container
count, residue count and age, rootless image inventory, and graphroot
free-space thresholds. `/data` is not to be remounted during adapter
specification.

## 24. Related records

- [ENG-0005 Capability Runtime design](../specs/2026-08-10-capability-runtime-design.md)
- [ENG-0005 non-executing implementation plan](2026-08-10-eng-0005-capability-runtime-implementation-plan.md)
- [Fabric governance boundaries](../../fabric/governance-boundaries.md)

## 25. External sources

Consulted 2026-08-10:

- [AppArmor — Ubuntu security documentation](https://documentation.ubuntu.com/security/security-features/privilege-restriction/apparmor/)
  — *"AppArmor can deny unprivileged applications the use of user namespaces…
  Applications requiring unprivileged namespaces must be explicitly allowed by
  their AppArmor profile."*
- [Understanding AppArmor user namespace restriction — Ubuntu Community Hub](https://discourse.ubuntu.com/t/understanding-apparmor-user-namespace-restriction/58007)
  — Ubuntu 23.10+ introduced the restriction; enablement is selective and under
  privileged-admin control.
- [Rootless containers — Podman documentation (DeepWiki mirror)](https://deepwiki.com/containers/podman/8-rootless-containers)
  — rootless mode maps container root to the invoking user via user namespaces;
  `newuidmap`/`newgidmap` from `uidmap` are the required setuid helpers.

Host-derived evidence — the shipped `/etc/apparmor.d/podman` and
`/etc/apparmor.d/unprivileged_userns` profiles from `apparmor
4.0.1-0ubuntu0.24.04.7`, and the `apt-get --simulate` package set — is more
specific to this host than any external source and is treated as authoritative
for it.

**Version context:** Ubuntu 24.04.4 LTS, kernel 6.8.0-136, apparmor
4.0.1-0ubuntu0.24.04.7, podman 4.9.3+ds1-1ubuntu0.2 (candidate), runc 1.3.6.
User-namespace and AppArmor behaviour changes with security updates; re-verify
before provisioning.
