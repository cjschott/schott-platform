# Execution Transition Boundary Design (ENG-0005)

**Status:** Proposed — not accepted

> **Architecture discovery only. This document authorises no host change and no
> implementation.** No helper exists, no sudoers entry exists, no unit file
> exists, no handoff directory exists, and no adapter is implemented. Every
> host fact below was obtained by read-only inspection on `schai`.

Resolves one question left open by
[Track B](../plans/2026-08-10-rootless-execution-prerequisite.md#22-track-b-provisioning-outcome-2026-08-11):

> How does the coordinator authorise **one already-prepared invocation** to
> execute under `kyri-capability` without receiving arbitrary
> privilege-transition, arbitrary Podman, or host-root authority?

Track B proved the sandbox. It did not provide a way to enter it. The
coordinator runs as `cschott`; execution must run as `kyri-capability`
(uid 999, `nologin`). Every Track-B execution crossed that gap through
`sudo` → `runuser`, which is exactly the authority this design must not grant.

## 1. The authority being requested

The desired semantic authority is one operation:

```
execute_prepared_invocation(CINV-nnnnnn)
```

It must be **narrower than** `run arbitrary command as kyri-capability`, and
much narrower than `access Podman`. The caller supplies one bounded reference
to work the coordinator has **already prepared and already made durable**, and
supplies no security-sensitive execution configuration whatsoever.

**The identity that crosses the boundary is `CINV`, not `invocation_id`.**
These are different values and conflating them would be a security defect. §4
of the [Capability Runtime design](2026-08-10-capability-runtime-design.md)
requires `invocation_id` to be *opaque, caller-supplied, and never parsed* — it
is attacker-influenced text of unbounded shape. `CINV-nnnnnn` is minted by the
runtime, matches `^CINV-[0-9]{6}$`, and is eleven characters of fixed grammar.
**Only the runtime-minted identifier may cross a privileged boundary**, because
only it can be totally validated by a parser small enough to audit.

That grammar is the single most important property in this design. It contains
no path, no separator, no option-looking prefix, no traversal sequence, and no
shell metacharacter, and it cannot be extended to contain one.

## 2. Normative transition requirements

Extracted from the Capability Runtime design, its implementation plan, the
Track-B prerequisite design, and the Track-B enforcement findings.

| # | Requirement | Source |
|---|---|---|
| 1 | Caller identity is authenticated by the kernel, never asserted by the caller | new |
| 2 | Exactly one permitted caller: the coordinator identity `cschott` | design §2 |
| 3 | The crossing reference matches `^CINV-[0-9]{6}$`, and nothing else | `identifiers.py` |
| 4 | The invocation record MUST already exist | design §6.11 |
| 5 | It MUST be in `execution-prepared` state | design §6, ledger |
| 6 | A refused invocation MUST NOT execute | design §6 |
| 7 | A conflicting invocation MUST NOT execute | design §16 |
| 8 | One execution attempt per `CINV`; a second attempt refuses | design §16 |
| 9 | Replay never re-executes; the prior record is returned | design §16 |
| 10 | Artefact is the A4 canonical staged object, by digest | design §8 |
| 11 | A per-invocation handoff is required; canonical staging stays unreachable | Track-B C |
| 12 | Payload is the A2 canonical bytes, digest-equal | design §5 |
| 13 | Image is operator-approved and digest-pinned | prereq §11 |
| 14 | The runtime profile is operator-owned and fixed | Track-B |
| 15 | `--network none` | design §10.2, prereq §7 |
| 16 | Memory, PID, CPU controls mandatory | Track-B |
| 17 | A bounded execution deadline | design §10.2 |
| 18 | Working and output paths explicit | design §10.1 |
| 19 | No caller-controlled Podman flag | new |
| 20 | No caller-controlled image | prereq §11 |
| 21 | No caller-controlled mount | new |
| 22 | No caller-controlled device | Track-B |
| 23 | No caller-controlled environment | design §10.1 |
| 24 | No arbitrary path crosses the privileged boundary | Track-B A |
| 25 | No arbitrary command crosses the privileged boundary | design §10.1 |
| 26 | Execution occurs as `kyri-capability` | prereq §5 |
| 27 | Container is not host-root; userns maps 0 → 999 | Track-B |
| 28 | No Podman socket or API is exposed to anyone | prereq §13 |
| 29 | `stdout`/`stderr` bounded, truncation recorded | prereq §15 |
| 30 | Output collected descriptor-safe and no-follow | Track-B A |
| 31 | Lifecycle state classified before `ExitCode` | Track-B B |
| 32 | Crash ambiguity recorded, never silently resolved | design §17 |
| 33 | Residue reported, never silently cleaned | prereq §14 |
| 34 | Invocation record durable **before** execution | design §10.1 |
| 35 | Every privileged transition is auditable to a caller and a `CINV` | new |
| 36 | The grant is removable by deleting one file, with no residue | new |

### Requirement conflict, reported before any mechanism is chosen

**Design §20 states: "no daemon, no worker service, no queue consumer, no
systemd unit, and nothing that keeps provider state alive between
invocations."** Read literally this forecloses TRANS-B and TRANS-C before
their merits are considered.

The narrow reading is that §20 governs the *Capability Runtime's own form*, and
a root-owned host component is not the runtime. **The narrow reading does not
rescue B or C**, because §20's stated rationale — added credential lifetime,
cancellation surface, and crash-recovery surface — applies with more force to a
component running as root than to one running as the coordinator. Prerequisite
§13 independently rejected the socket, the user service, and the system service
on the same grounds.

This design therefore treats §20 as disfavouring B and C rather than as
formally deciding them, evaluates all three, and reaches the same conclusion by
independent argument. **A reviewer ruling is requested** on whether §20 binds
host components (ruling R1, §12).

## 3. TRANS-A — narrow root-owned helper via scoped sudo

```
cschott (coordinator)
  → sudo /usr/libexec/kyri-exec-transition CINV-nnnnnn
    → root-owned helper, ~200 lines
      → validate caller, validate CINV grammar, resolve prepared record
      → establish handoff ownership
      → setgid/setuid → kyri-capability, no_new_privs
        → exec unprivileged worker
          → rootless Podman, fixed argv
```

### 3.1 Privilege boundary

Root does the minimum that only root can do, then leaves:

| Phase | Privilege | Responsibility |
|---|---|---|
| 1 | root | authenticate caller from `SUDO_UID`, cross-checked against the kernel-reported credentials |
| 2 | root | validate the argument against `^CINV-[0-9]{6}$` — total, no path resolution |
| 3 | root | read the prepared record; confirm `execution-prepared`, not refused, not conflicting, not already attempted |
| 4 | root | chown the pre-created handoff to the execution identity, read-only |
| 5 | root | `setgroups([987])`, `setgid(987)`, `setuid(999)`, verify the transition took, set `no_new_privs` |
| 6 | **unprivileged** | `execve` the worker as `kyri-capability` |

**Root never runs Podman.** Root never constructs container arguments, never
opens a caller-supplied path, never touches container output. Phases 1–5 are
the entire root-owned attack surface, and none of them parses anything larger
than eleven fixed characters.

### 3.2 sudoers analysis

The grant is one drop-in file. Its exact content is a matter for the
implementation increment, but its required properties are normative:

- **exact absolute path** — never a directory, never `ALL`, never a wildcard path;
- **one permitted caller**, `cschott`, and `runas` fixed to `root` only;
- **argument constrained by regular expression**, not shell wildcard. sudoers
  1.9 matches an argument beginning with `^` as a regex (sudoers(5), "If the
  arguments in a Cmnd begin with the `^` character, they will be interpreted as
  a regular expression"). The argument specification is therefore
  `^CINV-[0-9]{6}$` — the same grammar as the runtime identifier, **enforced by
  the sudo policy layer before the helper is executed at all**;
- **`NOPASSWD`**, because the coordinator is non-interactive — this is the one
  genuinely uncomfortable property, and it is bounded by every constraint above;
- **`env_reset` in force** with **no `env_keep` addition**. `env_reset` yields a
  minimal environment of `TERM`, `PATH`, `HOME`, `MAIL`, `SHELL`, `LOGNAME`,
  `USER`, and `SUDO_*` (sudoers(5)). The helper MUST NOT trust any of them and
  MUST construct the worker environment explicitly, as design §10.1 already
  requires of the coordinator;
- **no `setenv`**, no `!authenticate` beyond `NOPASSWD`, and no shell.

**Argument validation is not delegated to sudoers.** The regex is defence in
depth; the helper re-validates independently. A policy layer that is the *only*
validator is one syntax error away from being no validator.

### 3.3 Executable integrity

Three layers, and the first two are the ones that matter:

1. **Ownership.** The helper and **every ancestor directory** MUST be
   `root:root` and non-writable by `cschott`. `/usr/libexec` on this host is
   already `root:root`. sudoers(5) warns explicitly: *"if the user has write
   access to the command itself"* the grant is void — a digest cannot repair a
   writable binary.
2. **Digest pinning.** sudoers supports `sha224/sha256/sha384/sha512`
   `Digest_Spec` on a command; *"the command will only match successfully if it
   can be verified using one of the SHA-2 digests in the list"* (sudo ≥ 1.8.7;
   host has 1.9.15p5). This is **recommended in addition to** root ownership,
   because it converts a silent binary replacement into a failed match.
3. **Execution from the verified descriptor.** sudo's `fdexec` default is
   `digest_only`, which *"avoids a time of check versus time of use race
   condition"* by executing the descriptor it hashed. The classic
   hash-then-swap race is therefore closed by the mechanism, not by our code.

**Digest pinning has an operational cost that must be accepted deliberately:**
every helper upgrade requires a coordinated sudoers update, and a mismatch
fails closed — the transition stops working. That is the correct failure
direction, but it is a real operational burden and should not be adopted
absent-mindedly.

### 3.4 Environment model

The helper treats its entire inherited environment as hostile. It reads
`SUDO_UID` only as a cross-check against kernel-reported credentials, never as
the sole authentication. It clears the environment and constructs the worker's
explicitly — the same `env -i` discipline Track B proved, which produced a
four-variable container environment with a planted secret provably absent.

`LD_PRELOAD` and `LD_LIBRARY_PATH` are removed from any set-user-ID process by
the dynamic loader, and sudo's `env_reset` removes them again. **`PATH` is the
one to watch**: `secure_path` *"is not set by default"* per sudoers(5), and
`/etc/sudoers` is not readable by `cschott`, so **whether it is set on this
host is unverified** (ruling R2, §12). The helper MUST NOT depend on the
answer: it MUST use absolute paths for every executable it invokes.

## 4. TRANS-B — root-owned broker

```
coordinator → AF_UNIX request → root-owned broker → transition → Podman
```

**Authentication is the one thing this model does well.** `SO_PEERCRED` gives
the broker the kernel's own view of the peer's uid — unforgeable, better than
`SUDO_UID`. Socket mode `0600 root:root` plus a uid check is a sound gate.

**Everything else is worse.** A broker is a **persistent root process**. Its
attack surface is available continuously rather than for the milliseconds a
helper exists; a memory-safety or parser defect becomes a standing local
root vulnerability. It needs a request grammar, and a grammar needs a parser,
and a root-owned parser is the thing this design is trying not to have. It
needs lifetime management, restart behaviour, and crash semantics. It requires
a unit file and a runtime directory — **prohibited by design §20 and rejected
by prerequisite §13**.

**The decisive objection is API expansion.** A broker is an interface, and
interfaces accrete verbs. `execute_prepared_invocation` acquires `cancel`, then
`status`, then `list`, and the boundary this document exists to draw erodes one
reasonable-looking commit at a time. A helper cannot accrete verbs: it is one
executable with one argument, and adding a second operation means adding a
second sudoers entry that a reviewer must approve.

TRANS-B trades a better authentication primitive for a permanently larger root
attack surface. **Rejected**, with its one genuine advantage carried into R3
(§12): a helper could obtain the same unforgeable credentials by having the
coordinator connect to a socketpair, at the cost of complexity that
`SUDO_UID` + cross-check may not justify.

## 5. TRANS-C — systemd-mediated transition

Two variants, and they fail differently.

**Transient unit (`systemd-run --uid=999 …`).** This is *arbitrary*
`systemd-run` authority: the caller supplies `ExecStart=`, `User=`,
`Environment=`, mounts, capabilities, and resource properties. It is strictly
worse than NOPASSWD `runuser` — it grants arbitrary command execution as any
uid **plus** arbitrary unit-property injection. **Rejected outright.**

**Fixed root-owned template unit.** Better: `ExecStart=`, `User=`, and the
resource properties are frozen in a root-owned unit file and the caller
supplies only the instance name. This genuinely freezes security policy where
the caller cannot reach it. But:

- **starting a system unit requires privilege.** On this host `pkexec` is
  **absent** and `/etc/polkit-1/rules.d` contains **zero** rules. Authorising
  `cschott` to start the unit needs either a polkit rule (a new authorisation
  plane, on a headless host with no agent) or a sudoers entry for
  `systemctl start kyri-exec@…` — at which point sudo is in the design anyway
  and the unit is pure added machinery;
- **`cschott`'s own user manager cannot help.** systemd.exec(5): *"For user
  services of any other user, switching user identity is not permitted"*;
- **`User=` is not absolute.** systemd.exec(5) notes it *"does not affect
  commands whose command line is prefixed with `+`"* — a property-injection
  footgun in any design where a caller influences unit content;
- **a unit file is exactly what design §20 prohibits**, and the instance name
  would carry `CINV` into unit-name escaping, adding a parser rather than
  removing one.

**Rejected.** The fixed variant is defensible in principle and still requires
sudo or polkit underneath it, so it adds a systemd dependency and a second
authorisation plane without removing anything.

## 6. Rejected baselines

**Podman API / socket — REJECTED.** Exposing the rootless socket grants the
*entire* Podman API to anything that reaches it: create a container from any
image, any `--privileged`, any `--device`, any bind mount including the
repository or a socket, any network mode, any command, any environment. It
grants every authority requirements 19–25 forbid, in one step, permanently, and
grows with each Podman release. Track B masked the rootful socket and
demonstrated a working sandbox with **zero** listeners; re-introducing one
would discard that result. It also contradicts prerequisite §13, which chose
daemonless operation precisely because Docker's daemon was the rejected
property.

**General NOPASSWD Podman — REJECTED.** `cschott ALL=(kyri-capability)
NOPASSWD: /usr/bin/podman *` is the API rejection with extra steps. The
wildcard matches `podman run --privileged --network host -v /:/host …`, and
also `podman rm` of retained evidence and `podman pull` of an unapproved image.
sudoers wildcards are `fnmatch(3)` patterns, not a security policy; sudoers(5)
warns that complex argument validation is not their purpose.

**General `runuser`/`su` — REJECTED.** Grants *arbitrary command execution as
the execution identity*, not one governed invocation. It permits reading
`/data/kyri/capability` freely, mutating rootless storage, deleting evidence
containers, and running any binary as uid 999 — the entire authority the
boundary exists to withhold. This is precisely what Track B used, under
operator supervision, and precisely what must not become the production
mechanism.

**Coordinator = execution identity — REJECTED.** Collapses the two-identity
model. The coordinator would hold Fabric evidence, Trust access, the Capability
Runtime evidence store, canonical staging, **and** the sandbox it is supposed
to be isolated from. Track B's repository-access correction exists specifically
to keep the execution identity from reaching coordinator state; merging the
identities discards that correction and every guarantee derived from it.

## 7. Privileged-code minimisation and the authority source

**Should the privileged component read Capability Runtime records itself?**

**Model 1 — privileged component reads durable records.** The caller cannot
manufacture authorisation; root verifies `execution-prepared` from the store
itself. Cost: root gains read access to the coordinator's evidence store and
must understand its schema.

**Model 2 — coordinator issues a signed execution ticket.** A tiny privileged
parser, evidence logic left unprivileged. **Rejected**: nothing on this host can
sign such a ticket, and inventing a signing authority creates a new trust plane
with key custody, rotation, and revocation — vastly more surface than it saves.
The reviewer's instruction not to invent a signing system to rescue this model
is correct.

**Model 3 — drop privilege first, verify after.** Fatally circular: the
verifier would run as `kyri-capability`, the identity being authorised. The
execution identity cannot be the authority on whether it may execute.

**Recommended: Model 1, minimised.** Root reads exactly one record, by an
identifier it has already validated totally, from a path it constructs itself
from a compiled-in root and the validated `CINV` — **no caller-supplied path
component ever reaches an `open`**. It checks a small number of fields and
forms no opinion about anything else. Root gains read access to one directory
of the evidence store, which is a real cost, and it is smaller than any
alternative that does not invent a trust plane.

**Division of labour.** The unprivileged worker derives fixed Podman argv from
the operator-owned profile, executes, monitors lifecycle, and collects output.
**The worker's inputs must be treated as untrusted by the worker itself**: it
runs as `kyri-capability`, the same identity that owns rootless storage, so a
compromised worker cannot be assumed to follow its own rules. Its
trustworthiness comes from what it *cannot reach* — no repository, no canonical
staging, no Trust, no evidence write authority — not from its own correctness.
The privileged decision is complete before the worker starts.

## 8. Handoff, payload, and output

### 8.1 Artefact handoff

Canonical `/data/kyri/capability-runtime/staging` stays `0700 cschott:cschott`
and unreachable. Per invocation:

`/data/kyri/capability-handoff/<CINV>/` — coordinator-owned, mode `0711` on the
parent so the execution identity can traverse to a named child without
enumerating siblings; `0555` on the invocation directory; artefact `0444`.

**Copy, not hard link.** A hard link aliases the canonical inode into an
execution-reachable directory; permissions live on the inode, so canonical and
handoff cannot diverge, and an `unlink` in a directory the execution identity
can write would affect the canonical object's link count. The copy is made
**from the descriptor already opened and verified** — no source-path reopen —
then published atomically by `rename`, then re-verified by digest after
publication. This is the B10 discipline applied to a second hop.

Rootless Podman resolves bind-mount sources **as the execution identity**,
which is why traverse is required and why write is not. The coordinator does
not write into the directory after publication. Residue is reported, never
silently removed. Collision on an existing `<CINV>` is a **refusal**, since
requirement 8 permits one attempt.

### 8.2 Payload handoff

A2 canonical bytes, written as a file inside the same handoff directory, mounted
read-only. **Never argv, never environment.** Track B demonstrated why: argv is
world-readable through `/proc/<pid>/cmdline` — that is how the podman pause
process was classified — so any payload in argv is readable by every local
user. Bounded by the accepted A6 input bound; digest re-verified after
publication; no secret path exists, and an invocation requiring a secret
refuses before execution per design §18.

### 8.3 Output handoff

Threat-modelled rather than chosen to make Podman work:

| Model | Assessment |
|---|---|
| Execution-owned output root | Container writes freely; coordinator must later read a directory owned by the execution identity — **precisely the Track-B Finding A hazard**, and the coordinator is the privileged reader |
| Coordinator-owned, execution-writable subdirectory | Coordinator owns the root and controls the namespace; only the leaf is writable by uid 999 |
| Shared group | Widens standing authority for both identities; a group outlives the invocation |

**Recommended: coordinator-owned root, per-invocation execution-writable leaf.**
`/data/kyri/capability-handoff/<CINV>/out/`, owned by the coordinator, chowned
to the execution identity for the invocation, mounted read-write. The
coordinator retains the namespace; the execution identity gets one bounded leaf.

**The ownership model does not make the output safe.** Finding A stands
regardless: collection MUST walk descriptor-relatively with `O_NOFOLLOW`,
accept regular files only, reject symlinks, devices, FIFOs, and sockets,
enforce link-count, count, per-file, and aggregate bounds, and never cross the
output root. `tools/common/trusted_source.py` already implements the required
`openat` + `O_NOFOLLOW` component walk and should be extended rather than
duplicated.

## 9. Profile, image, lifecycle, crash, audit

**Runtime profile — operator-owned, frozen.** Capability and package metadata
MUST NOT choose network mode, privilege mode, image, registry, `--cap-add`,
device, mount, container runtime, socket, or the removal of any resource
control. Metadata attempting to influence these **refuses the invocation**
rather than being ignored, so an attempt is visible rather than silent. The
profile carries a version, and the version is recorded in evidence.

**Image authority.** Operator-approved enumerated set, digest-pinned, no
`latest`, no capability-selected registry, no pull during invocation,
pre-provisioned into graphroot; unknown or unpinned refuses. **The Track-B
Alpine digest is TEST-ONLY** and must not be promoted — it carries no language
runtime and was chosen to make isolation legible.

**Lifecycle.** Creation outcome → start outcome → terminal state → termination
mode → `ExitCode` **only after start is proven** → bounded output evidence.
`Created` or any never-started state is a launch failure regardless of
`ExitCode`, which Track B observed directly as `Created` with `ExitCode = 0`.

**Crash.** Design §17 already states the honest position and this design does
not weaken it: **at-most-once recorded, not exactly-once executed.** The
invocation record is durable before execution. A crash between start and
terminal persistence leaves a genuinely ambiguous window recorded as
interrupted, resolved by operator inspection and a new governed decision —
never by automatic retry, and never by Health.

| Failure point | Behaviour |
|---|---|
| before transition | no container; refusal recorded |
| after transition, before Podman | no container; attempt recorded |
| after create, before start | `Created` residue; **launch failure**, retained |
| after workload starts | terminal state recorded if reachable; otherwise interrupted |
| coordinator crashes | container may outlive it; detected by name at inspection, reported as orphan |
| helper crashes | root process is gone; no standing surface, unlike a broker |
| worker crashes | container may survive; reported as residue |
| host reboots | `runroot` on tmpfs clears; handoff on `/data` survives and is reported |

**Audit.** Every transition MUST durably record: caller uid from kernel
credentials, `CINV`, attempt identity, image digest, artefact digest, payload
digest, profile version, container name, created and started timestamps,
terminal state, exit code where applicable, timeout or kill state, and an
output evidence digest or reference. No secret content, no full payload, no
full output — digests and references only, consistent with the released "no
full prompts or responses by default" rule.

**Disk.** `/data` is `noquota`; cgroups bound memory, PIDs, and CPU but **not
disk**. Bounded by policy — handoff size, output count and bytes, retained
container count, residue age, image inventory, graphroot free-space thresholds
— not solved here.

**Deferred G interaction.** The six `0755` coordinator data roots are not
mounted into any container and are not on the transition path. But
`/data/kyri/capability-handoff` is a **new** root under the same parent, and it
MUST NOT inherit the `0755` habit: `0711` is specified above precisely so the
execution identity can traverse to a named child without enumerating the rest.
Deferred G should be resolved before the handoff root is created, so the
correction and the creation are one decision rather than two.

## 10. Comparison

| | TRANS-A helper+sudo | TRANS-B broker | TRANS-C systemd | TRANS-D Podman API | TRANS-E NOPASSWD podman/runuser |
|---|---|---|---|---|---|
| Least privilege | one op, one arg | one op, grammar | one unit, instance | **entire API** | **arbitrary** |
| Root attack surface | ~200 lines, milliseconds | persistent parser | systemd + polkit | n/a (uid 999, total) | n/a (total) |
| Persistent surface | **none** | **continuous** | unit + socket | **socket** | none |
| Caller input surface | 11 fixed chars | grammar | unit name | **unbounded** | **unbounded** |
| Auditability | sudo log + evidence | broker log | journal | weak | weak |
| Rollback | **delete one file** | unit + binary + socket | unit + polkit | mask socket | delete entry |
| Complexity | low | high | medium | low | trivial |
| Host dependencies | sudo | systemd + socket | systemd + polkit (**pkexec absent**) | podman socket | sudo |
| Two-identity model | preserved | preserved | preserved | **violated** | **violated** |
| No-daemon model | **compatible** | **violates §20** | **violates §20** | **violates §13** | compatible |
| Prepared-invocation evidence | verified by root | verified by broker | must be verified elsewhere | **none** | **none** |
| Handoff support | yes | yes | awkward | n/a | n/a |
| Failure isolation | helper exits | broker restarts | unit state | none | none |

**Trusted computing base.** All viable candidates share: kernel namespaces,
cgroups, seccomp, AppArmor; `newuidmap`/`newgidmap` (setuid, and the one
privileged component this design inherits from prerequisite §21); rootless
Podman 4.9.3; runc 1.3.6; the operator image policy; the handoff filesystem;
the Capability Runtime evidence store; and the coordinator. TRANS-A adds
**sudo and one short-lived root helper**. TRANS-B adds a **permanently
resident root process**. TRANS-C adds **systemd plus a second authorisation
plane**. Ranked by root-owned logic that must be correct, A < C < B.

## 11. Recommendation

### **TRANSITION-A — narrow root-owned helper recommended**

It is the only candidate that satisfies the authority model without violating
design §20 or prerequisite §13, and it is the smallest privileged surface of
the three. Its properties compose rather than merely coexist: the identifier
grammar is small enough to validate totally, the sudo policy layer enforces
that grammar independently before the helper runs, the digest and `fdexec`
close binary substitution and its TOCTOU, and the root process exists for
milliseconds and leaves nothing resident.

**Chosen despite sudo, not because of it.** The reviewer's instruction not to
assume `sudo`/`NOPASSWD` is acceptable is correct, and the distinction that
matters is between *sudo as a general privilege grant* — TRANS-E, rejected —
and *sudo as the invocation mechanism for one root-owned binary taking one
regex-constrained argument from one caller*. The second is a bounded grant
whose entire authority is visible in one file and removable by deleting it.

**`NOPASSWD` remains the least comfortable property in this design.** It is
required because the coordinator is non-interactive, and it is bounded by exact
path, single caller, fixed runas, regex-constrained argument, digest pinning,
and `env_reset`. It should be accepted explicitly, not by omission.

## 12. Reviewer rulings requested

- **R1 — does design §20's "no daemon, no systemd unit" bind host components,
  or only the Capability Runtime plane?** TRANS-A is unaffected either way;
  the ruling matters for whether B and C were ever admissible.
- **R2 — `secure_path` is unverified.** sudoers(5) says it is not set by
  default; `/etc/sudoers` is unreadable by `cschott`. An operator must report
  `sudo -V | grep -i 'secure path'` as root. The helper must not depend on the
  answer, but the answer belongs in the record.
- **R3 — caller authentication primitive.** `SUDO_UID` cross-checked against
  kernel-reported credentials, or a socketpair for `SO_PEERCRED`? The latter is
  strictly stronger and materially more complex.
- **R4 — is `NOPASSWD` accepted** under the bounding constraints of §3.2?
- **R5 — digest pinning accepted**, with its upgrade-coordination cost?
- **R6 — Deferred G before handoff-root creation**, so the `0755` question is
  settled once rather than inherited by a new root.

## 13. What this document does not do

It specifies no implementation, authorises no host change, creates no helper,
no sudoers entry, no unit file, and no handoff directory. It does not begin the
first-adapter specification, which remains a separate authorised step, and it
does not begin ENG-0006. **ENG-0005 still executes nothing.**

## 14. Related records

- [ENG-0005 Capability Runtime design](2026-08-10-capability-runtime-design.md)
- [Rootless execution prerequisite design](../plans/2026-08-10-rootless-execution-prerequisite.md)
- [ENG-0005 non-executing implementation plan](../plans/2026-08-10-eng-0005-capability-runtime-implementation-plan.md)

## 15. Sources and host versions

Host facts obtained by read-only inspection of `schai` on 2026-08-11:
Ubuntu 24.04.4 LTS, kernel 6.8.0-137-generic, sudo 1.9.15p5, systemd 255
(255.4-1ubuntu8.17), podman 4.9.3, runc 1.3.6 (crun not installed), apparmor
4.0.1-0ubuntu0.24.04.7, uidmap 1:4.13+dfsg1-4ubuntu3.2, polkitd
124-2ubuntu1.24.04.3 with **`pkexec` absent and zero polkit rules**,
Python 3.12.3.

Documentation consulted, in the versions installed on this host rather than
from memory: `sudoers(5)` for `Digest_Spec`, regular-expression argument
matching, `env_reset`, `secure_path`, the writable-command warning, and the
`fdexec` `digest_only` default; `systemd.exec(5)` for `User=` semantics and the
`+` prefix exception; `systemd-run(1)` for `--uid` and transient units;
`prctl(2)` for `PR_SET_NO_NEW_PRIVS` inheritance and irreversibility. Podman
behaviour for `--network none`, `no-new-privileges`, and cgroup-enforced
`--pids-limit`/`--memory`/`--cpus` was confirmed against the current upstream
`podman-run` documentation and, more importantly, against the Track-B
enforcement evidence measured on this host.
