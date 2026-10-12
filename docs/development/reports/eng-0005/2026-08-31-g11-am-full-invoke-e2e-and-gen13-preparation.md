# ENG-0005 G11-AM — the front half joined, and a result contract that is not there

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `41db9e189afd0811ba1cf3c4aa5bca2f042e073b`
**Implementation commit:** `f5d60cb`

The invoke front half is joined to a real container. One governed invocation
now runs from selected-evidence verification through to a workload writing its
result inside the admitted 5cee2b53 image, and seven failure rows drive from
the same path with no orphan surviving any of them.

Joining the halves is also what exposed the stop.

**The coordinator cannot tell a capability that succeeded from one that
produced nothing.** Both report `completed`. And no result record is written
for either, so the durable store says `execution-prepared` afterwards in every
case — the same words it used before the container existed.

That is two listed stop conditions at once: *"successful backend exit can be
misreported as invocation success after collection failure"* and *"CINV/CRES
lifecycle becomes ambiguous"*. §6 has the evidence. I stopped rather than
design a result-publication contract, which is architecture.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **87/87**, full **112/112**.

---

## 1. Starting authority

HEAD = `origin` = `41db9e1`, clean, both G11-AL commits ancestors. The exported
archive re-verified at `ec8213c9…41f3a`. Baseline quick 86/86, full 111/111.

## 2. The front-half call graph

Reconstructed mechanically before anything was built.

```
cli.command_invoke(args)
 └ prepare_invocation(store, …, adapter=None, execution_binding=None)
     ├ verify_selected_evidence(fabric, trust, CSEL, CINST, CPKG, operation, at)
     ├ resolve_and_stage_package(evidence, artifacts, staging)     [if supported]
     ├ bind(payload, invocation_id, selection, instance, package, operation, actor)
     ├ record_invocation(...)          ← CINV committed durably HERE
     │    ├ refused  → allocate CRES, return REFUSED
     │    └ prepared → return PREPARED, result_record_id = None
     └ if PREPARED and adapter and execution_binding:
            outcome = adapter.execute(execution_binding)
            return decision(status, outcome.outcome_class, …)
        else:
            return decision(status, "no_authorised_adapter", …)
```

**The released CLI cannot execute.** `command_invoke` never passes `adapter` or
`execution_binding` — there is no flag that would — so it always ends at
`no_authorised_adapter` and returns `EXIT_DENIED`. That is deliberate and
correct: the coordinator prepares, the privileged transition executes. It also
means the only route from the coordinator to a container is the injection seam,
which is what this harness uses.

| Durable mutation | Where | When |
| --- | --- | --- |
| staged package | `staging_root` | before the record, only if supported |
| **CINV record** | `store/capability-invocation` | **before the adapter is reached** |
| CRES record | `store/capability-result` | **only on refusal** |
| container | isolated Podman store | during `adapter.execute` |
| output | governed output leaf | by the workload |

The CINV is committed before execution deliberately, so a crash during
execution leaves a decision that was durably made rather than one nobody can
account for. That property holds and is proven below.

## 3. Fixture architecture

Shaped from the production Fabric, Trust and artifact stores and then standing
alone: every write lands in a temporary root, and the production stores are
opened read-only for the copy.

The evaluation instant is **derived from the records the fixture holds** — the
midpoint of the intersection of the instance's admission window and its
advertisement's validity — never from the clock. That is G11-AH's rule, and it
is why this suite does not begin failing when the production chain expires.

The image comes from the exported OCI archive into a disposable
`--root`/`--runroot`. No production graphroot is opened. Identity is required
to be exactly `5cee2b53…f5190`; no tag is consulted.

**Where privilege is concerned nothing is simulated.** The suite runs
unprivileged throughout. The credential drop it does not perform is the one the
transition performs before the worker process exists, so there is nothing here
to fake — and correspondingly, this harness does **not** exercise the
transition/worker hop, which needs sudo. That hop is covered by the
worker-binding suite and the backend probe, and §11 says so plainly rather than
letting the word "full" imply otherwise.

## 4. Full isolated invoke — success

```
preparation status                     prepared
execution outcome                      completed
CINV allocated                         True
package staged                         True
payload digest bound                   True
fabric authority unchanged             True
workload wrote the governed result     True
result content                         {'ok': True, 'value': 42}
host output owner preserved            (uid, gid) unchanged
output mode not widened                0o700
containers removed                     0
```

The whole path: `CSEL-000001` → `CINST-000002` → eligibility → operation
authority → `CPKG-0001` resolution and staging → binding → CINV → adapter →
real container as `65532:65532` under `keep-id`, network none, `--pull=never`,
read-only rootfs → `/usr/bin/python /kyri/package/main.py` → result written
through the governed output mount → collected by the invoking identity.

`FULL_ISOLATED_INVOKE_E2E = PASS` for the coordinator half.

## 5. Mutation manifest

| Object | Class |
| --- | --- |
| invocation store, CINV record | **PERSISTENT** |
| staged package | **PERSISTENT** |
| CRES record | **absent** — see §6 |
| container | **TEMPORARY**, removed; 0 remain |
| output leaf and result | **PERSISTENT** in the fixture root |
| fixture Fabric/Trust authority | **unchanged**, byte-compared before and after |
| production stores | **untouched** |

No unexplained residue.

## 6. The stop

### 6a. `completed` does not mean a result was admitted

`prepare_invocation` carries the adapter's outcome through as the decision
reason:

```python
outcome = adapter.execute(execution_binding)
return type(decision)(decision.status, outcome.outcome_class, …)
```

`AdapterOutcome` has **two** fields that matter here, and only one survives:

| Field | Meaning | Carried? |
| --- | --- | --- |
| `outcome_class` | what T13 concluded about the lifecycle | **yes** |
| `succeeded` | whether T14 admitted a **trusted result** | **discarded** |

So the harness observes:

| Case | workload | result written | `decision.reason` |
| --- | --- | --- | --- |
| success | writes `{"ok":true,"value":42}` | yes | `completed` |
| output-absent | `pass` | **no** | `completed` |

**Two materially different invocations, one indistinguishable answer.** The
adapter knows — `succeeded` is `False` for the second — and the coordinator
drops it. A caller reading the decision cannot tell a capability that did its
work from one that did nothing.

That is the listed stop condition in terms: *"successful backend exit can be
misreported as invocation success after collection failure."*

### 6b. Nothing durable records what the execution did

A result record is allocated **only on refusal**:

```python
if refusal is None:
    return InvocationDecision(STATUS_PREPARED, None, invocation_record_id=…)
    # result_record_id defaults to None
result_id = store.allocate_id(RESULT_KIND)   # refusal path only
```

Nothing writes one after execution. So every row of the failure matrix leaves
the **identical** durable state:

| Case | `decision.reason` | CINV | CRES | durable outcome |
| --- | --- | --- | --- | --- |
| wrong image | `adapter-error` | spent | none | `execution-prepared` |
| extra mount | `adapter-error` | spent | none | `execution-prepared` |
| socket mount | `adapter-error` | spent | none | `execution-prepared` |
| wrong identity mapping | `adapter-error` | spent | none | `execution-prepared` |
| workload exit 42 | `provider-error` | spent | none | `execution-prepared` |
| output absent | `completed` | spent | none | `execution-prepared` |
| governed timeout | `timeout` | spent | none | `execution-prepared` |
| **success** | `completed` | spent | none | `execution-prepared` |

Eight outcomes, one durable record. A CINV in `execution-prepared` cannot be
distinguished from one that never executed at all, which is the second listed
stop: *"CINV/CRES lifecycle becomes ambiguous."*

### 6c. Why I did not fix it

Closing this means deciding when a result record is allocated, what it binds
(outcome, output digest, reason, evidence), whether the coordinator or the
worker writes it, and how attempts are numbered. That is a governed contract,
not an implementation detail, and the brief is explicit: *"Do not silently
change already accepted identity-spending semantics."*

Options, smallest first:

1. **Carry `succeeded` through the decision.** One field. Fixes §6a and nothing
   else — the store still records nothing.
2. **Allocate a CRES at execution outcome**, bound to the CINV, carrying
   outcome class, admission, output digest and reason. Fixes both. Needs the
   result schema, which already exists for refusals, extended with an
   executed-outcome shape.
3. **Have the worker publish the result**, since it is the side that holds the
   output descriptor and the collected digest, with the coordinator reading it
   back. Most faithful to the privilege split; largest change.

I would recommend 2, with 1 as an immediate correctness patch if a ruling will
take time — but this is a design decision.

**Note this was not visible before.** Execution was unreachable until G11-AL,
so a prepared CINV that never executed was the only state there was. Joining
the halves is what turned a latent gap into a live one, which is what an
end-to-end is for.

## 7. Failure matrix

Driven from the real front half, not from the backend directly. Every row
asserts its outcome class and its durable state, and none leaves an orphan:

```
wrong-image          reason=adapter-error   containers=0  orphan=NO
extra-mount          reason=adapter-error   containers=1→0 orphan=NO
socket-mount         reason=adapter-error   containers=1→0 orphan=NO
wrong-user-mapping   reason=adapter-error   containers=1→0 orphan=NO
workload-exit-42     reason=provider-error  containers=1→0 orphan=NO
output-absent        reason=completed       containers=1→0 orphan=NO
timeout              reason=timeout         containers=1→0 orphan=NO
```

Six of the fourteen requested rows were not run: create failure, start failure,
kill, output unreadable, profile mismatch, and stale-eligibility-between-
preflight-and-invoke. The first five need fault injection below the backend;
the last needs the preflight extension (§9), which was not built.

**Replay is refused.** Re-invoking a spent identity returns
`status=consumed reason=invocation_identity_consumed`, so the durable CINV does
prevent a second execution under the same identity even though it records no
outcome.

**Timeout is terminal at the invocation layer.** The governed wall timeout
produces `timeout`, no result is admitted, and the container is proven stopped
with none remaining — carried from G11-AK's backend proof and re-observed here
through the coordinator.

## 8. CINV lifecycle

`CINV_LIFECYCLE = PASS`. The identity is allocated and committed at
preparation, **before** the adapter is reached, and is spent whatever the
container then does. That is the property that makes a crash during execution
accountable, and it holds: the exit-42 row shows the record durable and the
identity consumed after a failing workload.

## 9. Not built

- **Preflight backend readiness** (Phases 16–19). Unchanged. Phase 16 asks it
  to predict a CRES, which §6b shows is not predictable because none is
  allocated — so the stop reaches into this work.
- **Generation-13 installer, fixture ceremony, recovery matrix** (Phases
  21–28). The closure and matrix are known (§10); the installer was not
  written.
- Six failure rows (§7).

## 10. Generation 13

Recomputed; unchanged by this checkpoint, since no closure-reachable source
moved.

| | |
| --- | --- |
| entry closure | **68 objects**, reaching the backend naturally |
| generation delta | **10 objects** |
| REPLACE | 8 — `capability/cli.py`, `coordinator.py`, `evidence.py`, `package_resolution.py`, `store.py`, `execution/lifecycle.py`, `execution/profile.py`, `execution/worker.py` |
| CREATE | 2 — `capability/execution/mount_evidence.py`, `capability/rehearsal.py` |

**Coherence group A** stands: `/usr/libexec/kyri-exec-worker.py` and
`/usr/lib/kyri/python/kyri_exec_podman.py` must install together — the
entrypoint refuses without the backend and the backend without the entrypoint
is inert. No additional coherence group was introduced here.

`GEN13_ENTRY_CLOSURE = PASS`. `GEN13_PREINSTALL = NOT_READY` — no installer,
and now also because §6's ruling may add objects.

## 11. Helper, coordinator and sudoers

Unchanged and untouched. The installed helper is still `cfb0edd`-era on the two
transition modules; source coherence remains pinned so a mixed helper is
detectable from the halves alone. The coordinator authority candidate
revalidates byte-identical at `3dec888c…2811`. The sudoers grant pins
`/usr/libexec/kyri-exec-transition`, which the helper ceremony does not change,
so it already binds the final entrypoint.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES` — source tests passing
is not an installed helper being coherent.

## 12. Text-scan debt

In scope only for code this checkpoint touched, and none needed correcting: the
new harness asserts runtime behaviour throughout — decision fields, durable
record contents read through the store's own API, container inventory, file
ownership and modes — with no token scanning. The four assertions G11-AL
sharpened stay sharpened.

One method note worth keeping: the harness reads records through
`store.read_record` rather than a hand-built path. My first attempt guessed the
filename, and a guessed path proves nothing about a layout the store owns.

## 13. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 87/87 |
| `run-validation.sh` (full) | **PASS**, 112/112 |
| invoke execution E2E (new) | **PASS** — success, manifest, 7 failure rows |
| ShellCheck, pre-commit, static, developer-experience | clean |
| GitHub workflows | see handoff |

The new suite is host-only — it needs the production store shape, Podman and
the exported archive — declared in `tests/host-only.manifest`, which
`test-static.sh` enforces in both directions.

## 14. Production non-mutation

Production Fabric, Trust and artifact stores were read to shape the fixture and
never written. No production Podman storage opened, no production CINV or CRES
created, nothing staged, invoked or renewed. All containers ran in a disposable
store and were removed.

Not installed: worker entrypoint, backend, helper, sudoers, coordinator
authority, Generation 13. CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 15. Next operator checkpoint

None. The next step is a **ruling on §6**, which is engineering direction rather
than a ceremony. With it settled:

1. implement the chosen result contract, and extend the failure matrix to
   assert distinct durable outcomes per row;
2. preflight backend readiness, which can then predict a result identity;
3. the Generation-13 installer, whose object set §6's ruling may change;
4. then the deployment order stands as G11-AL left it — coordinator authority,
   the coherent helper, the worker/backend pair, Generation 13, and only then
   the Fabric sequence and a first production invoke.
