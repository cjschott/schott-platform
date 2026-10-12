# ENG-0005 G11-AP — supervision preconditions, and an orphan the coordinator cannot reach

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `cabf5b077a4cbbfe4aee176b7c35268b06a74832`
**Implementation commit:** `ec6ec0a`

The supervisor was not built, and the reason is one of the brief's own stop
conditions, established by experiment rather than by reading.

**A worker killed mid-execution leaves its container running.** `podman start
--attach` kills the client, not the container. Only `kyri-capability` can stop
it, and the coordinator has no Podman authority — correctly, and the brief
forbids adding any. Phase 26 requires proving either the worker cleans before
exit or the supervisor can reconcile. Neither is true, and Phase 15 requires
the supervision loop to guarantee no orphan. A loop written on top of that
would promise something it cannot deliver.

**What did verify is committed**, because it holds regardless of the ruling and
a future helper ceremony must not break it: the descriptor topology (Phase 31),
the protocol state machine (Phases 1–2), and the authority split.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **90/90**, full **115/115**.

---

## 1. The G11-AO stop

The coordinator cannot construct an execution binding — the snapshot it needs
lives in `/run/kyri/execution-material`, `root:kyri-capability`, unwritable by
the coordinator by design. So production execution must go through the
privileged transition, and the missing piece is the coordinator-side loop that
runs it and reads what the worker reports.

## 2. Phase 31 — the descriptor topology, and it passes

Checked first, because a helper that could not pass the protocol channels would
have ended the checkpoint immediately.

```python
PROFILE_FD = 3
INHERITED_DESCRIPTORS = (0, 1, 2, 3)
```

with the source's own reasoning:

> The protocol descriptors, plus the one governed exception: the sealed profile
> object the transition authors itself. This is not a return to ambient
> inheritance — no caller may name a descriptor number, and a caller descriptor
> that happens to occupy a governed one is replaced, never honoured.

**Exactly what a supervisor needs and nothing more.** No widening of
close-extra-descriptors is required, and none was made. The allowlist is a
compiled-in literal tuple of integers, not a computation over anything a caller
supplies — asserted from the AST so it stays that way.

`HELPER_PROTOCOL_FDS = PASS`, and it needed no change.

## 3. Phases 1–2 — the state machine

Enumerated from the released transition table rather than described, so a
supervisor written against it cannot drift from what the parser enforces:

| From | Message | To |
| --- | --- | --- |
| `start` | `created` | `created` |
| `created` | `verified_profile` | `profile_verified` |
| `profile_verified` | **`start_now`** | `start_sent` |
| `start_sent` | `started` | `started` |
| `started` | `terminal` | `terminal` |
| `terminal` | `collected` | `collected` |

`error` and `abort` terminate from any live state, and from neither `collected`
nor `ended` — which is what stops a second terminating message reopening a
closed session.

**Start authority is reachable from exactly one state.** `start_now` appears
only at `profile_verified`, so no malformed message can walk a session to a
point where starting looks legal. That is the ordering Phase 10 asks for, and
the parser already enforces it.

Six kinds flow worker→coordinator, two flow back, and the sets are disjoint.

## 4. The authority split

Asserted directly rather than assumed: the worker entrypoint reaches no
`CapabilityStore`, no `record_invocation`, no `record_terminal_result`, and no
`allocate_id`. `WORKER_WRITES_AUTHORITY = NO`.

The reason is worth keeping visible. If the worker could write a result there
would be two authors of the same fact, and the one holding Podman authority
would be the weaker of them.

## 5. Phase 26 — the stop

### What was proven

A container was created with the governed argv and a sleeping workload, then
the client was `SIGKILL`ed — modelling a worker that dies mid-execution, which
is the case a supervisor must handle and the one signal it cannot trap:

```
worker client SIGKILLed
container state after worker death: running  running=true
deterministic name available:      kyri-CINV-000042
```

**The container keeps running.** `podman start --attach` attaches a client;
killing the client does not stop the container.

### Why neither escape is available

**A — the worker cleans before exit.** False, and unfixably so for this case: a
`finally` cannot run after `SIGKILL`. Nothing calls the backend's `remove()`
today on any path, so even an orderly exit leaves the container — which is
consistent with the residue doctrine, but not with a supervisor promising no
orphan.

**B — the supervisor reconciles.** False. The coordinator has no Podman
authority, and Phase 26 forbids adding any. The container lives in the
`kyri-capability` rootless store, which the coordinator cannot even read.

### Why it is not merely cosmetic

Capacity is safe: *"the count comes from committed lifecycle records and
nothing else: not process counts, not container counts."* A stranded container
holds no slot.

But it is **still running**. It holds memory and CPU within its governed limits
with no supervisor, and it will run to its own completion or forever, depending
on the workload. That is materially different from exited residue, and it is
why this is a hard boundary rather than an untidiness.

### The smallest fix, not built

The container name is deterministic and CINV-derived —
`worker.container_name(profile.cinv)` produced `kyri-CINV-000042` above — so a
bounded reconciliation *is* expressible: a governed operation running **as
`kyri-capability`** that stops and removes the container for one named CINV,
reached through the existing privileged crossing.

That is a new privileged operation. It needs its own review: what it may name,
what it may remove, whether it may run without a fresh invocation, and how it
interacts with the interrupted classification. Adding it here — or giving the
coordinator Podman authority to avoid it — is exactly what the brief forbids.

`ORPHAN_CONTAINER = UNKNOWN` after worker death, and that is the honest value.

## 6. Not built

The supervisor, and everything behind it: CLI integration, the released CLI
E2E and its no-result case, supervised preflight, the Generation-13 installer
and recovery matrix. All are blocked on §5's ruling, not on effort.

## 7. Generation 13

Unchanged — no closure-reachable source moved this checkpoint.

| | |
| --- | --- |
| entry closure | **68 objects**, backend naturally reachable |
| generation delta | **12** — 10 REPLACE, 2 CREATE |

**Coherence groups**, unchanged and still correct. Group A: worker entrypoint +
Podman backend. Group RESULT: `coordinator.py`, `evidence.py`, `records.py`,
`inspection.py`. A supervisor, when written, joins Group EXECUTION with the
protocol parser — and the invariant the brief names would then bind: an install
exposing new execution protocol against old result semantics must be
impossible. The whole generation installs atomically, which satisfies it.

`GEN13_ENTRY_CLOSURE = PASS`, `GEN13_PREINSTALL = NOT_READY`.

## 8. Helper, coordinator and sudoers

Unchanged and untouched. Installed helper still `cfb0edd`-era on both
transition modules; source coherence pinned. The coordinator authority
candidate revalidates byte-identical at `3dec888c…2811`. The sudoers grant
pins an entrypoint the helper ceremony does not change.

**One addition to the helper ceremony's requirements**, from §2: it must
preserve `INHERITED_DESCRIPTORS = (0, 1, 2, 3)` exactly. A ceremony that
tightened it to `(3,)` — which would look like a hardening — would make the
supervision loop unbuildable. That is now pinned by test.

## 9. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 90/90 |
| `run-validation.sh` (full) | **PASS**, 115/115 |
| supervision preconditions (new) | **PASS**, 7 cases |
| adapter binding, result contract, invoke E2E | **PASS** |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

No existing assertion needed changing this checkpoint — the first in several.

## 10. Production non-mutation

`/var/lib/kyri/capability` remains absent; no production capability records
exist and none were created. No production Podman storage opened, no production
helper invoked, no production container executed. The one container created was
in a disposable isolated store and was removed.

Not installed: helper, sudoers, coordinator authority, Generation 13.
CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 11. Next operator gate

None. The next step is a ruling on §5, and it is a narrow one: **may a governed
container-reconciliation operation exist, running as `kyri-capability` and
reached through the privileged crossing, that stops and removes the container
for one named CINV?**

With yes, the supervisor becomes buildable and the remaining work is bounded:
supervisor, CLI, preflight, Generation-13 installer, in that order.

With no, the supervision loop must be specified to leave a running container
after worker death and say so, and the interrupted classification would need to
carry that meaning — which is a different and larger conversation about what
the platform promises.
