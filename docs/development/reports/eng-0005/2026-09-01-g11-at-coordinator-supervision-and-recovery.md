# ENG-0005 G11-AT — the coordinator learns what happened

**Date:** 2026-09-01
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `a94707ae2b6ef8da384400b25757cdefe6197cb7`
**Implementation:** `67f30a9`, `0f54289`, `99a106e`, `29502f3`, `9b5d5ce`, `7665ed0`

The supervisor exists, the released path finishes, and a worker killed while its
container runs no longer leaves an orphan the platform cannot see.

**Not built: the Generation-13 installer and its recovery matrix** (Phases 36
and 37). §18 says why, exactly, and what is required before they can be. Nothing
else in the brief was skipped.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **95/95**, full **120/120**.

---

## 1. Starting authority and the RED

G11-AS closed the execution identity and made the reconciliation entrypoint
reachable. What it left was a supervisor-shaped hole, and Phase 2 named it by
call graph rather than by searching for a word:

| Probe | Result |
| --- | --- |
| production callers of `protocol.encode` | **none** |
| constructions of `protocol.Session` | **one**, in the worker, over frames pre-read from descriptor 0 |
| `prepare_invocation(adapter=…)` in `cli.py` | **absent** — the released path always ended at `no_authorised_adapter` |

So the worker consumed `start_now` and reported nothing. Every message kind the
specification named for the worker to send existed as a schema and nothing else,
and the coordinator could authorise an execution and then learn nothing whatever
about it. The adapter seam the coordinator has always had was fillable only by
`PythonPodmanAdapter`, which runs *inside the worker* — on the far side of the
boundary the seam exists to cross.

## 2. The state machine

One table, walked from both ends. The worker sends where the coordinator
expects and the coordinator sends where the worker expects, so a second table
would be a second chance to disagree about what the conversation is.

```
              worker                    coordinator
  START  ──── created ──────────────▶   CREATED
  CREATED ─── verified_profile ────▶    PROFILE_VERIFIED
  PROFILE_VERIFIED ◀──── start_now ──   START_SENT
  START_SENT ─ started ────────────▶    STARTED
  STARTED ─── terminal ────────────▶    TERMINAL
  TERMINAL ── collected ───────────▶    COLLECTED   (complete)

  error / abort from either side, in any state before COLLECTED  ──▶ ENDED
  end of stream, in any state                       ──▶ not a state at all
```

**Start is authority.** `start_now` is the only message the coordinator sends in
the normal flow. It is reachable exactly once, only after a `verified_profile`
that correlates to this invocation, and only naming the container `created`
announced — and the table refuses it earlier, so an out-of-order grant is not a
mistake this code could make.

**T8 is not repeated on this side, and could not be.** The comparison that
matters is between the governed profile and the container Podman actually
created, and the observation exists only on the worker's side. What the
coordinator checks is the part that would otherwise be assumed: that the
profile the worker verified is the one *this* invocation sealed — digest,
implementation, image, schema version, and container identity. A worker that
verified some other well-formed profile perfectly would still not have verified
this one.

**Two fields joined `terminal`.** T13's outcome class travels rather than being
re-derived, because a reader recomputing it from the two facts beside it cannot
see `timed_out` at all and would file every timeout as a provider error. The
runtime's own timings travel because the durable record has to state when the
workload ran and the coordinator never saw it.

**The wire vocabulary is narrower than the released set.** Five classes, not
eight: `refused`, `cancelled` and `serialisation-failure` are conclusions
reached elsewhere and are not the worker's to claim, so there is no field value
that could carry one.

## 3. Descriptor topology

| Descriptor | Held by the coordinator | Seen by the worker | Why |
| --- | --- | --- | --- |
| 0 | write end of pipe A | coordinator's frames | the authority channel |
| 1 | read end of pipe B | worker's frames | the report channel |
| 2 | inherited | inherited | refusals reach the operator, not a pipe nobody reads |
| 3 | — | sealed profile | authored by the transition itself |

Launch keeps `(0, 1, 2, 3)` and **was not narrowed**. G11-AS gave reconciliation
`(0, 1, 2)` because it authors no profile and holds no session; applying that to
launch would have looked like hardening and would have broken the supervision
session this checkpoint exists to create. Both allowlists are pinned, in
opposite directions, by the reconcile-entrypoint suite.

The worker's reader is incremental rather than read-once. The coordinator cannot
write `start_now` until it has seen `verified_profile`, so a reader that drained
the stream before the conversation began would deadlock against a coordinator
waiting for this side to speak first.

## 4. Process ownership

The launcher owns the child completely: the supervisor asks it for frames and
for a bounded reap and never receives the process object, so there is no signal,
argument or descriptor it could reach around that class to touch.

`reap` closes both descriptors, waits within the bound, and — if the worker
outlives it — signals and waits again. An abandoned child is a zombie, and a
zombie is a process the platform has stopped accounting for.

**The exit status is never an outcome.** A worker that exits zero having said
nothing did not succeed, and a clean conversation whose worker will not end is
not a concluded execution: it yields no outcome either, because an unreaped
worker is a process still holding a container's attachment.

## 5. Normal success

```
created → verified_profile → START_NOW → started → terminal → collected
        → reap (exit 0) → reconcile → final_absent → outcome → CRES
```

Against a real container, from the exported OCI archive:

| | |
| --- | --- |
| outcome class | `completed` |
| succeeded | **true** |
| result digest | carried, `sha256:…`, concluded by T14 |
| protocol states | created, profile_verified, start_sent, started, terminal, collected |
| worker reaped | yes |
| disposal proven | yes |
| container afterwards | **absent** |
| coordinator's output tree | **none** — it holds no manifest and never did |
| `result_artifact_reference` | `null` by design (G11-AO Ruling A) |

## 6. Normal failure

Exit zero with no admissible result is `completed` with nothing admitted, which
`record_terminal_result` already names `result_missing` — the case that used to
read as success. Proven against a real container: outcome `completed`,
`succeeded` false, no digest, container absent.

Non-zero, timeout and adapter-error all travel as T13 concluded them and are
carried unchanged. A refusal the worker reaches is announced as an `error`
carrying its classification, and the coordinator believes it rather than
reinterpreting it.

**Deviation from Phase 18, stated.** The brief expected reconciliation only
where worker cleanup could not be proven. There is no worker cleanup: nothing
in the platform removes an execution container, and adding that to the worker
would give it a destroy path G11-AQ deliberately put behind a separate
authority. So **reconciliation is the disposal step on every path**, success
included. It is idempotent and treats absence as success, so it costs nothing
where nothing is left and is conclusive where something is — and "no orphan"
becomes a proven property of every execution rather than a claim about one.

## 7. Worker SIGKILL

The acceptance test three checkpoints have been building toward, run against a
real container:

```
CINV durable → worker launches → container created → profile verified
→ START_NOW granted → container RUNNING → SIGKILL the worker
→ protocol end of stream → worker reaped
→ reconcile(CINV) → name and label verified → stopped-and-removed
→ final_absent proven → CINV remains → CRES absent → interrupted
```

| Assertion | Result |
| --- | --- |
| no outcome was concluded | **pass** |
| no classification was invented | **pass** — death carries no claim about the workload |
| the conversation did not complete | **pass** |
| the worker was reaped | **pass** |
| reconciliation invoked for the exact CINV | **pass** |
| prior state observed | `running` |
| reconciliation outcome | **`stopped-and-removed`** |
| container identity verified before removal | **pass** |
| container afterwards | **absent** |

`WORKER_SIGKILL_ORPHAN_RECOVERED = PASS`. `ORPHAN_CONTAINER = NO`.

**The kill comes from the coordinator's side, and that is not a shortcut.**
`backend.start` attaches — it does not return until the workload has finished —
so there is no moment *inside* the worker where the container is running and the
worker holds control. That is exactly why the orphan exists, and it is what
G11-AP reproduced.

## 8. Reconciliation fallback and failure

Every path that does not conclude reconciles: a malformed frame, an unknown
kind, an out-of-order message, a wrong correlation, an end of stream at any
state, a worker that could not be reaped. None of them establishes the
container's fate, which is the whole reason the conversation mattered.

**A failure to prove disposal is never hidden.** It is not a warning on a
successful record and not a flag a reader can forget: the execution yields no
outcome, so no `CRES` is written and the invocation stays unresolved. Proven
with a real container left behind and a reconciler that refuses:

| | |
| --- | --- |
| outcome | **none** |
| conversation | **completed** — the workload ran and produced a result |
| disposal proven | **false** |
| container | still there to be found |
| durable result | **none** |

`RECONCILIATION_FAILURE_FAILS_CLOSED = YES`.

## 9. Coordinator death and recovery

**The signature.** G11-AO made this decidable by writing `adapter_identity` onto
the invocation record *before* the adapter is entered. An invocation carrying it
with no terminal result is one where execution was authorised and its outcome
was never established.

**Why a dead coordinator leaves exactly that**, proven structurally rather than
by killing a process at one chosen instant: there is exactly one point at which
a result becomes durable, and it is after the supervisor returns, which happens
only after disposal was proven. So every instant before that write leaves
`adapter_identity` set and no `CRES`. The call and return ordering is pinned in
both modules.

**Recovery**, run against the real container §8 left behind:

| | |
| --- | --- |
| enumerated from | two record kinds, never Podman |
| invocations found | the one with an adapter identity and no result |
| reported | `interrupted`, always — proving the container gone resolves the container, not the execution |
| reconciled | by `CINV`, through the governed operation |
| container afterwards | **absent** |
| results written | **0** |
| second pass | reports `absent`, changes nothing |

`INTERRUPTED_CRES_CREATED = NO`. No automatic replay exists anywhere in this
path; nothing retries and nothing resumes.

## 10. The execution-safety gate

`READY` means every unresolved invocation's container was **proven** absent.
`NOT_READY` means at least one could not be, whether because reconciliation
refused, could not run, or reported a container it would not touch. There is no
third verdict: "probably" is the answer this gate exists to refuse to give.

**It is not capacity.** Free slots say a container could be created; this says
whether creating one would be safe, because the guarantee every later
verification rests on — that a governed container belongs to exactly one live
invocation — is what an unresolved orphan makes untrue.

`SERVICE_READY_WITH_UNRESOLVED_ORPHAN = NO`, proven both ways: unknown state
gives `not-ready` and names the invocation; the same store after a real
reconciliation gives `ready`.

**Named for safety, not readiness.** The Capability Runtime is architecturally
barred from the health and orchestration plane — liveness, heartbeat, scheduling
— and `test-capability-runtime.sh` enforces that by identifier. Borrowing that
plane's vocabulary for a question decided entirely from this package's own
records would make the boundary harder to see for no gain. The verdict strings
are still `ready` / `not-ready`; only the identifiers differ.

**One boundary named rather than papered over.** The gate's scope is Phase 21's
definition — invocations with no result. A *successful* invocation whose
disposal failed cannot exist, because such an execution yields no outcome and
therefore no result, which puts it back inside the gate's scope. That is the
property that closes the hole, and it is why disposal is proven before an
outcome is concluded rather than after.

## 11. Released CLI

The flow was two steps and stopped one short. `execute` is the third.

```
capability invoke            → CINV durable, staged, prepared
capability authorise-launch  → handoff published, authorisation written
capability execute --cinv    → supervised, CRES written        ← G11-AT
capability recover           → unresolved containers resolved   ← G11-AT
```

`execute` takes **one CINV**. There is no `--adapter`, `--backend`,
`--execution-binding`, `--image`, `--argv`, `--container` or `--profile` — and
that is asserted, so "the caller does not choose what runs" is a property of the
surface rather than a rule about it. `recover` takes no invocation at all,
because the ones to resolve are the ones the records say were never resolved.

Reading back the published profile moved into `launch.py`, the module that
published it. An operator surface parsing a governed profile would be a second
reader of that module's own evidence, and it would need the profile parser to do
it — exactly the authority the launch CLI is asserted not to have.

`CLI_CALLER_SELECTS_ADAPTER = NO`.

## 12. What the CLI E2E does and does not prove

`CLI_FULL_ISOLATED_INVOKE`, `CLI_NO_RESULT` and `CLI_WORKER_DEATH` are reported
**NOT_RUN through the released binary**, and the reason is structural rather
than a gap in effort: `command_execute` opens `CAPABILITY_RUNTIME_ROOT` and the
handoff root as compiled-in production paths — deliberately, since an operator
able to name them could name another invocation's material — and it launches
through `sudo`, which is not granted on this host. A fixture cannot redirect
either without weakening the property that makes them safe.

What **is** proven, against real containers, is every layer beneath that seam:
the supervisor, the protocol, the adapter, the backend, the container, the
reconciler, and a SIGKILL that cannot be trapped. Success, no-result and worker
death are each proven there. What the released binary adds on top is argument
parsing, two file reads and a `sudo` invocation, and each of those is pinned
separately.

The first genuine end-to-end run of the released binary is a production
invocation, and it is the next operator checkpoint.

## 13. Supervised preflight

Read-only and mutating nothing: no helper invoked, no reconciliation run, no
`CINV` or `CRES` created, no snapshot materialised, no container created —
asserted from the call graph, not promised.

On this host, truthfully:

```
coordinator_identity_authority : false
execution_identity_authority   : false
helper_compatibility           : incompatible
helpers_blocking               : kyri-exec-transition          stale
                                 kyri-exec-worker.py           stale
                                 kyri-exec-reconcile           absent
                                 kyri-exec-reconcile-worker.py absent
launch_grant                   : unobservable
reconcile_grant                : unobservable
supervision_ready              : false
```

**`unobservable` is not `false`.** The two privilege grants live in a namespace
the coordinator may not read — by the same rule that keeps this surface out of
the elevation namespace at all — and claiming a verdict about them would be
claiming to have looked. Naming the mechanism at all would be this surface
reaching for it, which is why the fields are named for the grant rather than for
the file.

**Not a lease.** Nothing caches. `supervision_ready` is recomputed from the
authorities and the installed bytes on every call, and the helper enforces its
own authority regardless: a host that satisfied every observable precondition
and lacked the grant is refused by `sudo`, not by a remembered verdict.

## 14. Helper and runtime compatibility

`HELPER_RUNTIME_COMPATIBILITY = PASS` — the mechanism works and reports
`incompatible`, which is the correct answer here.

G11-AI found a host carrying half of one commit and the consequence was live.
Deployment order does not solve that on its own, because order is something an
operator does and this is something a machine can check. So the runtime declares
the four privileged objects its supervision path reaches and the exact bytes it
was built against, and reports each as `current`, `stale`, `absent` or
`unreadable`. There is no partial credit: a supervision path is only as current
as the object in it that is furthest behind.

The declaration is held to the sources it names by test — a digest table that
could drift from its own sources would be a compatibility check reporting
agreement with itself.

## 15. Generation 13 closure

Recomputed mechanically. **No manual whitelist**: two modules were reached only
by accident of how they were imported, and both were fixed at the source rather
than listed.

- `recovery.py` had no released entry root, so `recover` gave it one.
- `kyri_exec_launcher` was reached through `importlib`, which the closure cannot
  follow. It is now a literal import, because a surface somebody listed is not
  one the import graph requires.

| | G11-AS | now |
| --- | --- | --- |
| closure objects | 69 | **73** |
| runtime REPLACE | 10 | **13** |
| runtime CREATE | 3 | **9** |
| runtime delta | 13 | **22** |
| helper-ceremony objects in closure | 4 | 4 (3 REPLACE) |

New runtime objects: `supervision.py`, `recovery.py`, `helpers.py`,
`kyri_exec_launcher.py`, plus the six already declared. Replaced:
`protocol.py`, `adapter.py`, `lifecycle.py`, `launch.py`, `cli.py`,
`coordinator.py`, and the seven already declared.

The generation declaration in `g5-preflight.sh` carries every one of them, so
the checkout is a declared candidate rather than undeclared drift.

## 16. Coherence groups

| Group | Objects | Installed by |
| --- | --- | --- |
| **runtime execution** | `supervision.py`, `protocol.py`, `adapter.py`, `lifecycle.py`, `worker.py`, `kyri_exec_podman.py`, `kyri_exec_launcher.py`, `kyri_exec_worker.py` | Generation 13 |
| **result** | `coordinator.py`, `evidence.py`, `records.py`, `inspection.py`, `store.py` | Generation 13 |
| **recovery** | `recovery.py`, `helpers.py`, `cli.py` | Generation 13 |
| **deployment helper** | `kyri_exec_transition.py`, `kyri_exec_transition_action.py`, `kyri_exec_verify.py`, and the six `/usr/libexec` objects | privileged helper ceremony |

The first three must move together: a runtime supervising through the new
protocol while writing results under the old contract, or recovering with an
enumeration that predates `adapter_identity`, is a mixed state nothing else
would notice. The helper group stays separately installed and is
**compatibility-gated** by §14 rather than by ordering.

## 17. Deployment candidates

Revalidated, none installed.

| Candidate | State |
| --- | --- |
| coordinator identity authority | READY (G11-AH, unchanged) |
| execution identity authority | READY (G11-AS, unchanged) |
| launch helper | **re-derived** — `kyri-exec-worker.py` moved this checkpoint |
| reconcile helper | **re-derived** — unchanged bytes, restated in §14's table |
| launch sudoers | READY, digest unchanged at `0d9c8d8c…` |
| reconcile sudoers | READY, digest unchanged at `2878fff0…` |
| Generation 13 installer | **NOT_READY** — §18 |

Both sudoers digests are unchanged because neither entrypoint's bytes moved this
checkpoint. That is worth stating rather than assuming: `kyri-exec-worker.py`
*did* move, and the launch grant pins the entrypoint rather than the worker it
execs — which is why §14 exists. A grant that still matches is not the same as a
supervision path that is current, and the compatibility check is what tells the
two apart.

## 18. Why the Generation-13 installer is not here

`GEN13_PREINSTALL = NOT_READY`, `GEN13_RECOVERY = NOT_RUN`, and this is the one
part of the brief that did not land.

Two reasons, and the first is the honest one:

**Scale.** `install-generation-12.sh` is a 600-line transactional installer with
a matching failure-injection suite that replays every interrupted transaction at
every commit position. Building the equivalent for a 22-object delta across
three coherence groups, and proving that recovery yields whole-Gen12 or
whole-Gen13 and never a mixed supervision/result/recovery state, is a
checkpoint's work rather than the tail of one. Producing a thinner version and
calling it done would be worse than not producing it: the installer is the
object whose failure modes are least forgiving.

**Sequencing.** The installer pins the delta by digest, and the delta is only
final once the closure is. This checkpoint moved the closure twice while closing
the two whitelist gaps in §15, which is exactly the kind of movement an
installer must not be written against.

What is ready for it: the closure is computed and stable, every object is
declared in the generation delta, the coherence groups are enumerated in §16,
and §14 gives the installer a mechanical compatibility gate it did not have
before.

## 19. Deployment order

Derived from the code rather than assumed. Each step names what makes it a
prerequisite.

1. **Coordinator identity authority** — the launch helper reads it before
   anything else and has no constant to fall back to.
2. **Execution identity authority** — same, and the worker reads it again from
   the far side of the drop.
3. **Coherent launch + reconcile helpers** — all six objects, together. §16's
   helper group; a partial install is the G11-AI defect.
4. **Verify both helper digests** — `helpers.compatibility()` reports
   `compatible`, or nothing after this point is safe to install.
5. **Generation 13** — runtime, result and recovery groups in one transaction.
6. **Verify Generation 13.**
7. **Supervised preflight, read-only** — expect everything except the two
   grants; `unobservable` is the correct answer for those.
8. **Renew CADV** — the Fabric chain has expired.
9. **Admit a bounded CINST.**
10. **CROUTE successor**, then **CSEL**.
11. **Install the two narrow sudoers grants** — last, because until here there
    was nothing safe for them to authorise.
12. **`capability invoke --preflight`**, then `invoke`, then `authorise-launch`.
13. **One controlled `capability execute`** — the first production run of the
    released binary.
14. **Verify CINV, CRES and the result digest.**
15. **`capability recover`** — expect `ready` and zero unresolved.
16. **Withdraw the grants** if the architecture rules them temporary.

Steps 1–4 are new to this ordering and are the ones §14 made checkable.

## 20. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 95/95 |
| `run-validation.sh` (full) | **PASS**, 120/120 |
| supervision (new) | **PASS**, 31 cases |
| supervised execution E2E (new, host-only) | **PASS** — real containers, real SIGKILL |
| protocol, adapter, lifecycle, worker, backend | **PASS** |
| identity authority, reconcile entrypoint, reconciliation | **PASS** |
| capability runtime, launch CLI, invoke E2E | **PASS** |
| G5 preflight, provisioning, helper coherence | **PASS** |
| ShellCheck, Semgrep, pre-commit | clean |
| GitHub workflows | see handoff |

### What went wrong on the way

Worth recording, because two of the three are recurrences.

**A suite passed while running a fragment.** An unescaped `"` inside a comment
terminated the bash string that carries a case script, so the case ran a
truncated program and reported PASS. Found by accident. Afterwards I compiled
all **994** case scripts across every suite in the repository: nothing else was
truncated, and the two backtick escapes ShellCheck caught were mine from the
same session.

**Three source scans failed on prose.** A docstring saying a module starts no
subprocess is the opposite of it starting one, and a substring scan cannot tell
those apart. All three now strip docstrings and read the AST. This is the same
mistake this project has caught in my work repeatedly; the fix is always to
assert on structure.

**A deadlock I wrote into a fixture.** A scripted child waited for authority it
would never be granted while the coordinator waited for a message that would
never come. Fixed in the fixture, not by shortening a timeout.

## 21. Production non-mutation

Not installed: coordinator identity, execution identity, launch helper, reconcile
helper, sudoers, Generation 13. No production helper invoked, no sudo used, no
production workload executed, no production CINV or CRES created, no Fabric
renewal, no production Podman storage opened.

Every container in this checkpoint was created and removed in a disposable store
under `/tmp`, from the exported OCI archive. `/etc/kyri`, `/etc/sudoers.d`,
`/usr/libexec` and `/usr/lib/kyri` are unchanged; `/var/lib/kyri/capability`
remains absent.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 22. Next

**The Generation-13 installer and its recovery matrix** (§18), against the
closure this checkpoint made final. That is the last engineering step before the
deployment order in §19 can begin, and it is the whole of the next checkpoint.
