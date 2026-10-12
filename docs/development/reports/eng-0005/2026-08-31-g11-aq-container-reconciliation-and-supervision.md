# ENG-0005 G11-AQ — the orphan, recovered

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `8fe85bace0d4e323b4b30c389e170a3957faf784`
**Implementation commit:** `a7c5e73`

G11-AP's hard boundary is closed. A worker killed mid-execution leaves a
running container, and there is now a governed operation that recovers exactly
that container and nothing else — proven by reproducing the orphan and then
removing it.

**Not built:** the coordinator supervisor, the CLI path, preflight, and the
Generation-13 installer. The guarantee they depend on now exists; the work
does not. §11 says what remains.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **91/91**, full **116/116**.

---

## 1. The stop, reproduced

The defect proof runs first in the acceptance suite, so the recovery that
follows is demonstrably recovering something real:

```
deterministic name                   PASS  'kyri-CINV-000042'
container running before the kill    PASS  'running'
worker client is dead                PASS  True
container SURVIVES worker death      PASS  'running'
```

`podman start --attach` attaches a client. `SIGKILL` on that client kills the
client. The container keeps running, a `finally` clause cannot help because
`SIGKILL` is the one signal a process cannot trap, and the coordinator has no
Podman authority and must not gain any.

## 2. Phase 1 — where reconciliation belongs

**Option B: a separate helper binary.**

The transition entrypoint takes exactly two argv elements and says why:

> There is no option parser here on purpose: an option parser is a place for
> flags to be added later.

Adding a `reconcile` subcommand would introduce exactly that. A separate
entrypoint keeps each at one CINV argument, keeps launch and reconciliation
authority separable — which the brief prefers — and lets sudoers grant them as
two distinct rules against two distinct digests. It also matches the existing
pattern: `kyri-exec-verify` is already a second entrypoint beside
`kyri-exec-transition`.

## 3. The operation

`provisioning/execution/kyri-exec-reconcile.py`, installing to
`/usr/lib/kyri/python/kyri_exec_reconcile.py`.

**It is not Podman authority.** One operation, one invocation identity, and a
closed set of things it may do to exactly one container. It cannot list
containers, manage images, prune anything, or act on a container a caller
names.

**The only value crossing from outside is a CINV**, checked totally — no
stripping, no case folding, no normalisation, because each of those turns an
input that should have been refused into one that was accepted. Refused:
`cinv-000042`, `CINV-00042`, `CINV-0000042`, `kyri-CINV-000042`,
`CINV-000042 `, `../CINV-000042`, `CINV-000042; rm -rf /`, empty, `None`,
integers, lists.

The backend's name-keyed primitives refuse anything that is not
`kyri-CINV-nnnnnn`, so even an internal caller cannot compose a name.

## 4. Name is not identity

This is the part worth the code. A name is a string anything could occupy, and
this operation stops and removes what it finds.

So the runtime now writes a label on every governed execution container:

```
io.kyri.invocation-id=CINV-000042
```

Reverse-DNS like every other label on the admitted image, written from the
**authenticated profile's own CINV**, so the label and the deterministic name
cannot disagree about which invocation the container belongs to. No package
data, operator input, or metadata reaches it.

Reconciliation requires **both**, and the negative cases are the evidence:

| Container | Outcome | State afterwards |
| --- | --- | --- |
| right name, right label | `stopped-and-removed` | absent |
| right name, **wrong** label | **`refused`** | **untouched** (`created`) |
| right name, **no** label | **`refused`** | **untouched** (`created`) |
| a different invocation's container | `absent` for the asked CINV | **untouched** |

A refusal always leaves the container exactly as it was found. An orphan left
visible is better than an unrelated container removed.

## 5. The state machine

Closed. `created`, `running`, `exited`, `paused`, `stopping` are recognised;
anything else refuses rather than guessing what to do with it.

| Prior state | Action | Outcome |
| --- | --- | --- |
| absent | none | `absent` |
| `exited` / `created` | remove | `removed-exited` |
| `running` / `paused` / `stopping` | bounded stop → observe → bounded kill → observe → remove | `stopped-and-removed` |
| still running after stop **and** kill | none further | `failed` |
| unreadable or unrecognised | none | `refused` |

**Not fire-and-forget.** The entire value of the operation is being able to say
the container is stopped, and that requires observing it. Removal is likewise
proven: the final absence is confirmed by lookup, because a remove that
reported success while leaving the container present would be exactly the false
guarantee this exists to avoid.

## 6. Idempotence

Absence is a *success*, so the operation is idempotent by construction. Proven:
a second run against an already-reconciled invocation returns `absent` and does
nothing.

```
second run is already-absent          PASS  'absent'
still absent                          PASS  True
```

## 7. Privilege

The reconciler is a pure module taking an injected backend, so it can be
exercised without root — which is how this suite drives it, modelling the
operation running as `kyri-capability` after the drop.

**No root Podman.** The intended entrypoint mirrors the existing
transition→worker and verify→verify-worker shape: root validates the caller,
the coordinator authority and the CINV, then drops permanently to 999:987 with
`HOME=/data/kyri/capability` and `XDG_RUNTIME_DIR=/run/user/999`, and only then
is Podman reached. That entrypoint is **not written** — §11.

## 8. It concludes nothing about the capability

Stopping a container says nothing about how far the workload got. The reconciler
writes no result and never touches the invocation record, so an invocation whose
supervision was lost stays **interrupted** — which G11-AO made decidable and
which is the honest reading.

`INTERRUPTED_CRES_CREATED = NO`.

## 9. The result protocol

A closed structured report, not Podman stdout: `invocation_id`, `outcome`,
`prior_state`, `container_identity_verified`, `final_absent`, `reason`.

`final_absent` is the field a supervisor would act on, and it is only ever true
where absence was confirmed by lookup.

## 10. Generation 13

Recomputed. Unchanged at **68 objects**, delta **12** (10 REPLACE, 2 CREATE) —
`worker.py` was already in the delta and the label change did not add one.

`kyri_exec_reconcile.py` is deliberately **not** in the runtime closure: like
the transition helper it is privileged-helper authority, installed by the
helper ceremony rather than the generation installer. That separation is why
the deployment order matters, and §11 records the new compatibility
requirement.

## 11. Not built, and what now depends on what

- **The reconcile entrypoint** — root validation, permanent drop, exec of a
  reconcile worker. The logic exists and is proven; the privileged wrapper is
  not written.
- **The coordinator supervisor**, which was blocked on this guarantee and is
  now unblocked.
- **Coordinator-death recovery** (Phases 17–21), which needs the supervisor and
  a readiness gate.
- **CLI, preflight, Generation-13 installer.**

**A new deployment requirement**, from §10: the helper ceremony must now
install *two* governed operations, and a runtime that supervises executions
assuming reconciliation exists must not be installed against a helper that
cannot provide it. Generation and helper are separate authorities, so the
ordering is load-bearing: helper first, then the generation that depends on it.

## 12. Sudoers

Two rules, not one, so review can distinguish them and either can be withdrawn
alone:

```
Cmnd_Alias KYRI_EXEC_TRANSITION = sha256:<digest> \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$
Cmnd_Alias KYRI_EXEC_RECONCILE  = sha256:<digest> \
    /usr/libexec/kyri-exec-reconcile  ^CINV-[0-9]{6}$
```

Same regex semantics G11-AI pinned for sudo 1.9.15p5, same digest pinning, no
wildcard, no container argument, no shell. The reconcile digest cannot be
computed until its entrypoint exists, so `RECONCILE_SUDOERS_CANDIDATE =
NOT_READY` — the shape is settled, the digest is not.

`LAUNCH_SUDOERS_CANDIDATE = READY`, unchanged and still uninstalled.

## 13. Helper and coordinator candidates

Unchanged. Installed helper still `cfb0edd`-era on both transition modules;
source coherence pinned. Coordinator authority candidate revalidates
byte-identical at `3dec888c…2811`. The descriptor allowlist `(0, 1, 2, 3)`
remains pinned by test — a ceremony that tightened it would look like hardening
and would break the future supervisor.

## 14. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 91/91 |
| `run-validation.sh` (full) | **PASS**, 116/116 |
| container reconciliation (new) | **PASS** — orphan reproduced, recovered, idempotent, refusals |
| Podman backend, worker binding, supervision preconditions | **PASS** |
| ShellCheck, pre-commit, static, developer-experience | clean |
| GitHub workflows | see handoff |

One existing assertion moved, and it was mine: it counted `stdin=DEVNULL`
occurrences against a literal `2`, and now counts them against the number of
`subprocess.run` calls and requires every one to carry the same six controls.
A literal count would have had to be edited every time a process site was
added; the structural form cannot be satisfied by adding an unguarded one.

## 15. Production non-mutation

No production Podman storage opened; every container was created and removed in
a disposable store. No production helper invoked, no sudo used, no reconcile
authority installed. `/var/lib/kyri/capability` remains absent.

Not installed: helper, sudoers, coordinator authority, Generation 13.
CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 16. Next

No operator gate. The next engineering step is the reconcile **entrypoint** —
root validation, permanent drop, exec — because it is what turns a proven
module into an operation the coordinator can actually reach across the
privilege boundary. The supervisor follows it, then coordinator-death recovery
and readiness, then CLI, preflight and Generation 13.
