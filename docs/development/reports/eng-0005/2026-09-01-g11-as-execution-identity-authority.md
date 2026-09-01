# ENG-0005 G11-AS — the second deployment identity

**Date:** 2026-09-01
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `c80d31aec6fd9b4161c665a63d7a5988c5d85ab0`
**Implementation:** `44591be`, `03a2e90`, `2e3a39d`, `843ac3c`

The G11-AR stop is closed. The execution identity is now read from root-owned
deployment authority, the seven compiled-in sites are gone, and the privileged
reconciliation entrypoint that could not be safely written now exists.

Two facts are worth stating before the detail:

**The numbers disappear as production constants.** Not renamed to
`EXECUTION_UID = 999` — removed. What remains anywhere in `tools/` or
`provisioning/` is four operator ceremonies whose subject is this accepted host,
enumerated in §8.

**Every case runs two unrelated deployments.** 999:987 and 2203:2207, through
the same code, because a suite that only ever exercised the schai values would
pass against a constant just as well.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **93/93**, full **118/118**.

---

## 1. The G11-AR stop

> If the existing deployment authority currently only governs the coordinator
> and no equivalent worker identity authority exists: STOP.

It did, and there was none. `/etc/kyri/coordinator-identity.json` carried a
closed three-field schema naming only the coordinator; `backing-store.json`
anchored a filesystem and carried no identity at all. The execution identity
lived at seven sites in three modules, and building a privileged entrypoint
whose entire job is to *become* that identity would have meant reading them —
reproducing, inside a new privileged binary, the defect G11-AH had already
removed from the launch helper.

## 2. The reviewer ruling, and what it decided

A distinct deployment-bound execution identity authority, separate from the
coordinator record, because the two are separate security roles.

That separation is not stylistic. The coordinator prepares invocations and may
never touch Podman; the execution principal holds rootless Podman authority and
may never write Capability Runtime records. One file naming both would make the
two roles editable together and would read as if the split were a detail of one
document rather than the boundary the whole transition exists to create.

## 3. Authority precedent

Phase 1 was answered from the tree before anything was written.

| Question | What the repository already does |
| --- | --- |
| pathname | `/etc/kyri/<role>-identity.json` — `coordinator-identity.json` is the only instance, beside `backing-store.json` |
| directory | `/etc/kyri`, `root:root 0711` — traversable, not listable, so a 0444 file inside is readable by name |
| ownership | root uid **and** root gid, and not writable by group or world; read bits deliberately unconstrained |
| encoding | one bounded JSON object, duplicate keys **refused** rather than collapsed, bound applied to raw bytes before parsing |
| schema style | role-prefixed fields plus `schema_version`; closed both ways — unknown field and missing field both refuse |
| provisioning | provisioned, never generated; malformed is a refusal, not a prompt to write a fresh one |
| reading | descriptor-relative, directory opened `O_NOFOLLOW`, file opened relative to it, status taken from the descriptor that was opened |
| fallback | none — `COORDINATOR_UID` does not exist as a constant, so there is nothing for a failure to degrade to |

The conceptual pathname the brief preferred is exactly what the convention
produces, so no deviation was needed.

## 4. The record

`/etc/kyri/execution-identity.json`, schema version 1:

```json
{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}
```

Field names are role-prefixed because the coordinator record is, and because
`execution_uid` self-describes in a codebase where a bare `uid` would be
ambiguous — `profile.EXECUTION_UID` is the *container's* 65532 and has nothing
to do with this. §7 pins that they stay apart.

**What is deliberately not in it:** the coordinator identity, `HOME`, the Podman
graphroot, `XDG_RUNTIME_DIR`, the OCI image, the container identity, network
policy, sudoers, `CINV`, capability scope. It answers one question — which local
kernel identity may execute capability workloads and own the rootless execution
substrate — and adding a second would make it the place other authorities came
to live.

`XDG_RUNTIME_DIR` is **derived** from the uid rather than stored beside it. The
rootless runtime directory is a function of the identity, and a record carrying
both could state a pair that disagreed with itself.

## 5. Account and numbers must agree

The record carries the name *and* the numbers, and loading resolves the account
through the system account database and requires them to still match.

This deliberately differs from the coordinator authority, whose own source says
a name "would have to be resolved through NSS at the privileged boundary — a
lookup the helper must not depend on." That remains correct **for the
coordinator**, because the fact it needs is `st_uid` on a descriptor it already
holds, and NSS would be a dependency it does not need.

This identity is a different kind of thing: a target to *become* rather than a
publisher to recognise. The failure it must survive is a stale authority naming
an account whose uid was later reassigned. A number alone cannot notice that; a
name alone would put NSS in charge of what the platform becomes. Carrying both
and requiring agreement is a fact neither could establish on its own.

| Case | Outcome |
| --- | --- |
| record and database agree | accepted |
| database resolves the name to a different uid | **refused** |
| database resolves the name to a different primary gid | **refused** |
| uid agrees, gid does not (or the reverse) | **refused** |
| account unknown to the database | **refused** |
| database unusable | **refused** |

The resolver is **injected**, and it is not in the policy module. That module is
the pure decision layer — provably testable without privilege — and the T10
backstop forbids it `pwd` and `grp` for exactly that reason. Consulting the
account database is a syscall dependency, so it lives in the action layer with
every other one, while the *binding* still happens inside the parser where a
caller cannot skip it. Requiring the resolver rather than defaulting it also
stops a test quietly asserting against the host's own database, which is the
coincidence this record exists to stop depending on.

## 6. The seven sites, closed

| Was | Now |
| --- | --- |
| `kyri-exec-transition.py` `WORKER_USER` | `identity.account`, from the authority |
| `kyri-exec-transition.py` `WORKER_UID` / `WORKER_GID` | `identity.uid` / `identity.gid` |
| `kyri-exec-transition.py` `ENVIRONMENT` → `/run/user/999` | `execution_environment(identity)`, derived |
| `worker.py` `WORKER_UID` / `WORKER_GID` | required `identity` argument |
| `worker.py` `ENVIRONMENT` → `/run/user/999` | `identity.environment(identity)`, derived |
| `kyri-exec-podman.py` `BACKEND_ENVIRONMENT` → `/run/user/999` | **removed**; `environment` is now required |

`policy_for` requires the identity, so there is no signature that produces a
transition policy without one — an unpoliced identity is not a path somebody
could forget to take, it does not exist. The same is true of the reconciliation
policy and of `PodmanBackend`, whose default carried one deployment's runtime
directory and therefore could only ever be correct on one host.

**One of the seven was mine**, added in G11-AK when I followed the existing
pattern in the backend without questioning it.

## 7. Four identities, still four

| Identity | Bound to | This deployment | Pinned by |
| --- | --- | --- | --- |
| coordinator | deployment authority | `cschott` 1000 | coordinator-identity suite |
| execution worker | deployment authority | `kyri-capability` 999:987 | identity-authority suite |
| container | adapter contract | 65532:65532 | container-identity suite |
| invocation | the runtime | `CINV-nnnnnn` | reconciliation suite |

No numeric relationship between any pair is required or implied, and the
container case is now asserted against **two** host deployments rather than
against one constant: `fixture-a` 999:987 and `fixture-b` 2203:2207 both govern
the same 65532:65532 container contract, with the mapping `65532:0:1` unchanged.
That is the property that would break if the two were ever collapsed, and a
comment in `profile.py` describing the host identity as a fixed pair was
corrected.

## 8. What still says 999 or 987, and why

Phase 7 asked for a classification, not a zero.

| File | Class |
| --- | --- |
| `g5-ceremony.sh` | operator ceremony verifying this accepted host |
| `g5-preflight.sh` | operator ceremony verifying this accepted host |
| `g11-ai-image-export.sh` | operator ceremony verifying this accepted host |
| `install-generation-6.sh` | operator ceremony that created the account |

Nothing else. The scan is a token match — `999_999` is a sequence bound and a
hex digest containing `9999` is a digest — and it is pinned as a test, so a new
production site cannot appear quietly.

**Migrating the ceremonies is correct and must follow installation.** Until
`/etc/kyri/execution-identity.json` exists, a ceremony that read it would refuse
on every host including this one. That is the next small piece of work, not this
checkpoint's.

## 9. Storage authority

`EXECUTION_STORAGE_AUTHORITY = PASS`, with the boundary stated plainly, and
**no `home` field was invented**.

- **The filesystem is governed.** `backing-store.json` names the filesystem
  type, UUID and mount point `/data`, and `verify_backing_store` anchors a
  verified descriptor to the device it actually sits on.
- **The subpath is platform layout.** `/data/kyri/capability` is in the same
  class as `EXECUTION_ROOT`, `HANDOFF_ROOT`, `HELPER_PATH`,
  `RUNTIME_LIBRARY_ROOT` and the authority path itself: a property of Kyri, not
  of a deployment. It does not vary by host, so it is not the defect the uid
  was.
- Corroborating but not depended on: it is also the resolved account's own
  passwd home on this deployment.

**For the reviewer.** If the position is that the subpath must be governed too,
that is a question about all four `/data/kyri/*` roots together and a separate
small checkpoint — not a field on a record that names a principal.

## 10. Two parsers, one specification

The privileged helpers install beneath a root that must stay usable without the
runtime package, so the grammar exists twice: `kyri-exec-transition.py` for the
helpers and `tools/capability/execution/identity.py` for the runtime.

This is the discipline `PROFILE_FD` and `REQUIRED_SEALS` already get, applied to
behaviour rather than to a number. Roughly thirty vectors — unknown field,
missing field, bool-as-int, zero, negative, out of range, string and float
numbers, empty and malformed accounts, duplicate keys, two documents, non-UTF-8,
oversize, wrong owner, wrong group, group- and world-writable, a directory, a
symlink — are driven through **both** and required to produce the same verdict.
A parser pair that can disagree is a boundary that can be crossed one way and
not the other.

Both also refuse a coordinator authority document, and the launch and reconcile
paths share one parser by construction rather than by inspection.

## 11. The launch helper

Ordering preserved exactly, with the authority read first:

```
execution identity authority  →  policy  →  launch authorisation  →  quota
→  descriptor closure  →  setgroups  →  setgid  →  setuid
→  permanent-drop verification  →  no_new_privs  →  exec worker
```

Nothing was reordered to accommodate the loader. The drop itself was factored
into one `drop_privilege` shared by both transitions — a second copy of a
credential-drop sequence would be a second thing to keep correct and a first
thing to get wrong, which is the argument `kyri_exec_verify` already makes about
the policy. The quota suite's ordering assertion now follows the call into that
function rather than looking at one function, because an assertion that only
looked at the caller would have been satisfied by moving the drop elsewhere.

The worker confirms the drop from the far side of `execve` by reading the same
authority again — two independent reads of one root-owned record rather than one
side trusting the other. Its reader is resolved through the governed
installed-root seam, not a bare import: a host whose runtime predates the reader
refuses in the platform's own vocabulary instead of raising `ImportError`.

## 12. The reconciliation entrypoint

`/usr/libexec/kyri-exec-reconcile CINV-nnnnnn`. No container name, no uid, no
image, no flag, no option parser.

**A second entrypoint, not a subcommand** (Ruling 1, unchanged from G11-AQ). Two
paths, two digests, two grants, either withdrawable alone. The launch entrypoint
keeps its two-argv shape and gains no verb.

**Root does exactly this**: validates the argument shape, reads and validates
the execution identity authority, resolves the account and binds it to the
numbers, builds the policy, closes descriptors, drops permanently, verifies the
drop in every component, sets and reads back `no_new_privs`, and execs. There is
no quota — reconciliation writes no output — and no launch record, because
nothing about a container's existence is authorised by one.

**Podman is unreachable while `euid` is 0**, by construction. Neither the
entrypoint nor the action module imports the backend or the reconciler; the
worker that does is reached only through `execve`, which the ordering proof
places after the drop. Asserted from the import graph rather than from a text
ban.

**The whole path is helper-ceremony authority.** It imports nothing from
`tools.capability`, so a host that has not yet taken a Generation can still
recover an orphaned container — which is when recovery matters most.

## 13. Descriptor policy

`RECONCILE_INHERITED_DESCRIPTORS = (0, 1, 2)`, derived rather than copied.

Descriptor 3 is on the launch list because the transition seals a profile object
onto it. Reconciliation authors no profile and holds no protocol session with a
worker, so there is nothing for a fourth descriptor to carry.

`INHERITED_DESCRIPTORS = (0, 1, 2, 3)` is **untouched** — narrowing it would
break the supervision session it exists for, and a ceremony that tightened it
would look like hardening.

Proven two ways: the recorder captures the exact allowlist the production code
asked for, and a forked child opens a real descriptor at 17 and confirms the
system backend's own closure closes it.

## 14. Privilege proof — this deployment

`RECONCILIATION_RUNS_AS_KYRI_CAPABILITY = PASS_BY_DECISION`, and the
qualification is deliberate.

The authority resolves `kyri-capability` 999:987, the real entrypoint decision
path runs unmodified, and the recorder captures `setgroups((987,))`,
`setgid(987)`, `setuid(999)` in that order, followed by full-component
verification, `no_new_privs`, and an `execve` of the reconcile worker with
`HOME=/data/kyri/capability` and `XDG_RUNTIME_DIR=/run/user/999`.

**A real drop was not performed, and could not be.** It requires root — there is
no passwordless sudo here — and a real drop to 999 driving rootless Podman would
open the production graphroot, which this checkpoint is forbidden to touch. So
the credential primitives are injected recorders: the seam the launch transition
has been tested through since T11.

What that proves is the ordering and the arguments. What it cannot prove is that
Linux honours `setuid`, which is not a property of this repository. The actual
orphan recovery remains proven by G11-AQ's isolated-store suite, which still
passes.

`PERMANENT_PRIVILEGE_DROP = PASS` on the same basis, and it is verified in every
component rather than the effective one: a saved uid still root, an effective
uid still root, a surviving root group, an emptied group set, and a drop to
*another* identity are each refused before the exec.

## 15. Privilege proof — alternate deployment

`fixture-b` / 2203:2207, through the same source, with no production change.

Every reconciliation case runs both deployments. Each produces its own
`setuid`/`setgid`/`setgroups` arguments, its own `/run/user/<uid>`, and its own
launch and reconciliation policies. The worker's identity check accepts each
under its own authority and **refuses each under the other's** — which the
compiled-in version would have failed on one and passed on the other, and which
is exactly the assertion a renamed constant could not satisfy.

No semantic 999 survives in any module this exercises; the fixture values live
only in the test.

## 16. Negative matrix

| Case | Outcome |
| --- | --- |
| malformed `CINV` (11 forms, incl. `kyri-CINV-000042`, `../`, trailing space, `; rm -rf /`) | refused by **both** the entrypoint grammar and the reconciler's |
| second argument, `--force`, empty argv | refused |
| a launch policy handed to `perform_reconciliation` | refused |
| `assume_root` false | refused, nothing spent |
| authority missing / not a regular file / symlink / directory | refused |
| authority owned by the coordinator or by the execution principal | refused |
| authority in a non-root group, or group- or world-writable | refused |
| account, uid or gid mismatch (each direction) | refused |
| unknown account | refused |
| incomplete drop (8 shapes) | refused before exec |
| `no_new_privs` not readable back as set | refused before exec |
| failure at any credential primitive | refused before exec |
| right name / wrong label, right name / no label, absent, exited, running, unknown state | G11-AQ outcomes, unchanged |

`RUNTIME_STORE_MUTATED = NO`. The reconcile worker imports nothing from
`tools.capability`, calls no store constructor and no record writer — asserted
from the import and call graphs, because `store` occurs inside `storage` and
inside the module's own explanation of what it does not do.

`INTERRUPTED_CRES_CREATED = NO`. Stopping a container concludes nothing about
how far the workload got.

## 17. Execution identity ceremony candidate

`provisioning/execution/g11-as-execution-identity-candidate.sh`, read-only.

The account name is the only input; every number comes from the account
database. A ceremony that printed a body somebody typed would reproduce the
defect one directory further out.

```
account        kyri-capability
uid            999
primary gid    987
```

```json
{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}
```

| | |
| --- | --- |
| bytes | 99 |
| sha256 | `891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373` |
| destination | `/etc/kyri/execution-identity.json` (**absent**) |
| owner / mode | `root:root` `0444` |
| rehearsed | accepted by **both** parsers, from the same bytes |

`EXECUTION_IDENTITY_CANDIDATE = READY`. **Not installed.** The freeze block
refuses if the destination exists.

## 18. Sudoers

Both digests are computable now, and the launch digest **changed** — the launch
entrypoint reads the authority before building the policy, so its bytes moved
and the old candidate is void.

```
Cmnd_Alias KYRI_EXEC_TRANSITION = sha256:0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1 \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$
Cmnd_Alias KYRI_EXEC_RECONCILE  = sha256:2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77 \
    /usr/libexec/kyri-exec-reconcile  ^CINV-[0-9]{6}$
cschott ALL=(root) NOPASSWD: KYRI_EXEC_TRANSITION
cschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE
```

`visudo -c` under sudo **1.9.15p5**: **parsed OK**. Two rules, not one, so either
can be withdrawn alone; no wildcard, no container argument, no shell. The
principal `cschott` is derived by `sudoers_principal()` from the coordinator
authority candidate rather than typed in.

`RECONCILE_SUDOERS_CANDIDATE = READY`, `LAUNCH_SUDOERS_CANDIDATE = READY`
(re-derived). **Neither installed** —
`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`, and the digests bind
to bytes that are still only in the checkout.

## 19. Cumulative privileged helper delta

Measured against the live installed state.

| Object | Installed | Proposed | State |
| --- | --- | --- | --- |
| `kyri_exec_transition.py` | `6488044bc824` | `de264c6490e0` | **REPLACE** |
| `kyri_exec_transition_action.py` | `bd32af5de4f3` | `7703231318f7` | **REPLACE** |
| `kyri_exec_verify.py` | `3d70707d19c3` | `f49c29571a4e` | **REPLACE** |
| `kyri_exec_quota.py` | `4886d5b323c9` | `4886d5b323c9` | unchanged |
| `kyri_exec_podman.py` | absent | `cf26b29810e4` | **CREATE** |
| `kyri_exec_reconcile.py` | absent | `29175d5a7175` | **CREATE** |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf6342` | `0d9c8d8c9181` | **REPLACE** |
| `/usr/libexec/kyri-exec-verify` | `fad96924adbb` | `1c87788c6559` | **REPLACE** |
| `/usr/libexec/kyri-exec-quota` | `4886d5b323c9` | `4886d5b323c9` | unchanged |
| `/usr/libexec/kyri-exec-worker.py` | `64260190330b` | `f52352b647c0` | **REPLACE** |
| `/usr/libexec/kyri-exec-verify-worker.py` | `5a614ff73c0d` | `c747c6d0c306` | **REPLACE** |
| `/usr/libexec/kyri-exec-reconcile` | absent | `2878fff04bb2` | **CREATE** |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | absent | `b0e3c047f689` | **CREATE** |

Eleven objects move; two do not. `INSTALLED_HELPER_STILL_STALE = YES` — the
installed helper is still `cfb0edd`-era on the transition modules and now also
behind on the verification surface.

## 20. Coherence

`HELPER_COHERENCE = PASS`.

The reconciliation surface joined the existing ceremony set rather than getting
one of its own, because it shares the policy module, the action module and the
credential drop with the launch path. A host carrying a reconcile entrypoint
over an older action module would be the 16f285e defect again with a different
pair of halves — so the suite now asserts that pairing directly: the entrypoint
calls `execution_identity` and `perform_reconciliation`, the action module
provides both, and the policy module provides `reconciliation_policy_for`.

It also pins that **both** privileged paths drop through the one shared
implementation and that neither performs its own credential calls.

**Authority coherence** (Phase 23): the helper and the runtime are held to the
same path, the same closed schema, the same version and the same byte bound, and
the vector corpus is the anti-drift mechanism. The authority *file* is
deliberately **not** one of the ceremony's objects — it is deployment authority
with its own ceremony, and a helper that installed it would be choosing the
deployment's identity rather than reading it.

**Deployment ordering**, unchanged from G11-AQ and now sharper: helper ceremony,
then the execution identity authority, then the Generation. A Generation whose
worker reads the authority must not be installed against a host that has not
been given one — the worker refuses, which is correct and is also an outage.

## 21. Generation 13

Recomputed mechanically, not carried forward.

| | G11-AR | now |
| --- | --- | --- |
| entry closure | 68 | **69** |
| runtime REPLACE | 10 | **10** |
| runtime CREATE | 2 | **3** |
| runtime delta | 12 | **13** |

The one new object is `tools/capability/execution/identity.py`.
`verification.py` also changed and is **not** in the closure — nothing among the
declared entry roots imports it, because the verification worker is a `libexec`
entrypoint rather than a library module. It is installed, so the G5 preflight
declaration covers it independently of the closure, which is the mechanism
working as intended: the closure answers "what must be importable", the
declaration answers "what installed bytes changed".

`kyri_exec_reconcile.py`, the reconcile entrypoint and the reconcile worker
remain outside the runtime closure as helper authority (Phase 26). The four
flattened helper objects inside the closure are installed by the helper
ceremony, not the Generation installer, and the split is stated rather than
inferred.

One extension to the declaration format was required and is worth review: a
`REPLACE` row may now name `ABSENT` as a baseline, for an object created after
the oldest fixture the declaration is checked against but already installed on a
newer host. `verification.py` is the first object in that state — absent from
the generation-6 fixture, present and changing on this host — and one
declaration has to describe both, because it is checked against both. The
checkout side is still absolute and a host that *has* the object must still hold
a named baseline or the new bytes.

## 22. Future preflight requirement

Not built. What a supervised-invoke preflight must report, recorded so the next
checkpoint does not have to re-derive it:

| Check | Ready state |
| --- | --- |
| coordinator identity authority | present, root-owned, parses, names a non-root uid |
| **execution identity authority** | present, root-owned, parses, account resolves and binds |
| launch helper digest | matches the reviewed bytes the sudoers rule pins |
| reconcile helper digest | matches the reviewed bytes its own rule pins |
| launch sudoers grant | installed, digest current |
| reconcile sudoers grant | installed, digest current |
| backend and image | Podman reachable as the execution identity; `CIMP-000001` present |

**A runtime with a valid coordinator authority and no execution identity
authority is NOT ready.** It is the state this host is in right now, and the
worker refuses on it.

## 23. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 93/93 |
| `run-validation.sh` (full) | **PASS**, 118/118 |
| identity authority (rewritten) | **PASS**, 15 cases |
| reconcile entrypoint (new) | **PASS**, 12 cases |
| helper coherence (extended) | **PASS**, 8 cases |
| container identity, podman backend, lifecycle, quota, helper policy | **PASS** |
| G5 preflight, provisioning, worker binding, reconciliation | **PASS** |
| ShellCheck, Semgrep, pre-commit | clean |
| GitHub workflows | see handoff |

Two of my own new assertions were wrong and had to be rewritten before they
passed — both the same class of mistake this project keeps catching. One banned
the substring `store` in a module whose docstring explains it holds no store;
one banned a runtime's name in a module whose docstring explains it starts no
process. Both now read the AST. A third scanned lines for `999` and matched
`999_999` and a hex digest; it now matches tokens.

## 24. Production non-mutation

Not installed: the execution identity authority, the coordinator authority, the
launch helper, the reconcile helper, sudoers, Generation 13. No production
container ran, no production helper was invoked, no sudo was used, no account
was created, no production Podman storage was opened, no Fabric renewal, no CINV
or CRES.

`/etc/kyri` unchanged and still holding no identity record. `/etc/sudoers.d`
holds only the distribution README. `/var/lib/kyri/capability` absent.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 25. Next

**The coordinator supervisor**, which G11-AQ unblocked and which now has a
reachable reconciliation operation to call across the privilege boundary.

Then coordinator-death recovery and readiness, the released CLI path, the
preflight in §22, and Generation 13.

Two smaller items, both consequences of this checkpoint: migrate the four
operator ceremonies in §8 to read the authority once it is installed, and a
reviewer decision on §9 if the storage subpath is to be governed too.
