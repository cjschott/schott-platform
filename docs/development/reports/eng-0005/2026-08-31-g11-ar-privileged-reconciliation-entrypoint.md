# ENG-0005 G11-AR — the entrypoint that cannot be written yet

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `9011e5f9ee4dcc69e1f85bedc06a72671a7c98ae`
**Implementation commit:** `71c1e8c`

The privileged reconciliation entrypoint was not written, and Ruling 3 is the
reason — not as a judgement call, but as a fact about what authority exists.

The entrypoint's whole job is to drop to the worker identity. **The only way to
learn that identity today is to read compiled-in constants.** Building it would
have reproduced, inside a new privileged binary, exactly the defect G11-AH
removed from the launch helper. The ruling forbids that and forbids inventing
an identity file to fix it.

So the gap is bounded rather than papered over, and the missing authority is
specified precisely enough that closing it should be short.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **92/92**, full **117/117**.

---

## 1. Phase 1 — what governs which identity

Answered mechanically before any code, which is what the brief asked.

**A. The coordinator identity is deployment-bound.**
`/etc/kyri/coordinator-identity.json`, root-owned, read through
`load_coordinator_authority`, with a closed three-field schema:
`coordinator_account`, `coordinator_uid`, `schema_version`. `COORDINATOR_UID`
does not exist as a constant — there is deliberately nothing to fall back to.

**B. The worker identity is a compiled-in universal.**

```
provisioning/execution/kyri-exec-transition.py:61  WORKER_USER = "kyri-capability"
provisioning/execution/kyri-exec-transition.py:62  WORKER_UID  = 999
provisioning/execution/kyri-exec-transition.py:63  WORKER_GID  = 987
tools/capability/execution/worker.py:60            WORKER_UID  = 999
tools/capability/execution/worker.py:61            WORKER_GID  = 987
```

and the uid is embedded in path strings, so even the rootless runtime directory
is assumed:

```
kyri-exec-transition.py:106   ("XDG_RUNTIME_DIR", "/run/user/999")
worker.py:85                  ("XDG_RUNTIME_DIR", "/run/user/999")
kyri-exec-podman.py:68        ("XDG_RUNTIME_DIR", "/run/user/999")
```

**Seven sites, three modules.** One of them — the backend's — I added myself in
G11-AK, following the existing pattern without questioning it.

**C.** The launch helper determines its final execution identity from those
constants and from nothing else.

**D. Reconciliation cannot reuse that mechanism without broadening the defect.**
A second privileged binary reading the same universals doubles the surface that
would have to change when a deployment differs.

### The absence is proven, not assumed

The coordinator authority schema is closed and names no execution identity —
`worker_uid`, `worker_account` and `execution_uid` are all absent from it. The
only other root-owned deployment record is `backing-store.json`, which anchors a
filesystem (`filesystem_type`, `filesystem_uuid`, `mount_point`) and carries no
identity at all. There is nowhere in accepted authority for the execution
identity to be provisioned.

## 2. Why this is the same defect, not a similar one

G11-AH left its reasoning in the source it corrected, and it needs no
adaptation:

> A compiled-in coordinator uid used to live at this line. It was never derived
> and never provisioned: it was true of `schai` because `cschott` happens to be
> uid 1000, and three suites passed on that coincidence. **A helper meant to be
> deployment-independent cannot carry one deployment's account number as if it
> were a property of Kyri.**

Substitute `kyri-capability` for `cschott` and 999 for 1000 and the paragraph is
about the worker. The correction was applied to one identity and not the other.

`HARDCODED_WORKER_UID_GID` is therefore **YES** — a statement about the tree as
it stands, not about anything this checkpoint introduced.

## 3. The missing authority, specified

Small, and shaped like the one that already exists:

- **Where.** Beside `backing-store.json` and `coordinator-identity.json` in
  `/etc/kyri`, root-owned, provisioned and never generated, malformed being a
  refusal rather than a prompt to write a fresh one.
- **What.** The execution account and its uid/gid — the three facts the drop
  needs — plus a schema version. Whether it is a new record or two fields added
  to the coordinator authority is the reviewer's call; the coordinator schema is
  closed, so either way it is a schema change.
- **Read by.** The launch helper and the reconciliation helper, at the same
  point the coordinator authority is read.
- **The rule that makes it worth having.** No constant to fall back to. A
  fallback is what let the coordinator uid survive unnoticed.

Also worth deciding in the same ruling: `/run/user/<uid>` is derived from the
uid, so it should be *computed* from the authority rather than stored, or the
same number ends up in two places again.

## 4. What was built instead

A suite that **bounds** the gap. It does not assert the gap is acceptable and
does not assert a fix.

| Case | What it holds |
| --- | --- |
| coordinator identity is deployment-bound | authority path, closed schema, **no** `COORDINATOR_UID` constant |
| no authority governs the worker identity | coordinator schema names no execution identity; backing store carries none |
| the worker identity is stated at exactly seven sites | the migration checklist; an eighth cannot appear unnoticed |
| the reconciliation module names no identity | which is why *it* was implementable in G11-AQ |
| no privileged reconciliation entrypoint exists | the deliverable's absence, so the handoff cannot drift from the tree |

The uid and gid are **read from source** rather than restated, so the suite does
not become an eighth place that states them.

## 5. Architecture decisions that stand

**Separate helper (Ruling 1).** Unchanged from G11-AQ: reconciliation gets its
own entrypoint, its own digest, its own sudoers grant, independently
withdrawable. The launch entrypoint keeps its two-argv shape and gains no option
parser.

**One external value (Ruling 2).** The reconciliation module already accepts
exactly one CINV and derives everything else; G11-AQ proved the refusals. The
entrypoint would add root-side validation ahead of it, not a second input.

**No root Podman (Ruling 4).** The module takes an injected backend and names no
identity, so Podman is unreachable until after the drop by construction. That
property is already pinned.

**Descriptor policy (Phase 8).** Reconciliation needs no protocol channels, so
its allowlist should be `(0, 1, 2)` — narrower than launch's `(0, 1, 2, 3)`,
which stays as it is. The two helpers having different allowlists is correct and
was the point of separating them. Not implemented, because the entrypoint is
not.

## 6. Sudoers

`RECONCILE_SUDOERS_CANDIDATE = NOT_READY`, and for the same reason as G11-AQ:
the digest cannot be computed until the entrypoint bytes exist. The shape is
settled — approved coordinator, exact helper path, `^CINV-[0-9]{6}$` under sudo
1.9.15p5 regex semantics, no wildcard, no container argument.

`LAUNCH_SUDOERS_CANDIDATE = READY`, revalidated and unchanged. Nothing here
broadened it; the launch grant, its digest and its argument regex are untouched.

## 7. Cumulative privileged delta

Unchanged from G11-AQ, because no privileged source moved:

| Object | Installed | Proposed | State |
| --- | --- | --- | --- |
| `kyri_exec_transition.py` | `cfb0edd`-era | HEAD | **REPLACE** |
| `kyri_exec_transition_action.py` | `cfb0edd`-era | HEAD | **REPLACE** |
| `kyri_exec_verify.py` | current | current | — |
| `/usr/libexec/kyri-exec-transition` | current | current | — |
| `/usr/libexec/kyri-exec-worker.py` | stale | HEAD | **REPLACE** |
| `kyri_exec_podman.py` | absent | HEAD | **CREATE** |
| `kyri_exec_reconcile.py` | absent | HEAD | **CREATE** |
| `/usr/libexec/kyri-exec-reconcile` | absent | **does not exist** | **blocked** |

The ceremony is not yet writable in full: it would install a reconciliation
module with no entrypoint to reach it.

## 8. Generation 13

`GEN13_RUNTIME_DELTA_FROM_AR = NONE`, derived rather than assumed. Closure
**68 objects**, delta **12** (10 REPLACE, 2 CREATE) — identical to G11-AQ. No
runtime object changed this checkpoint, and `kyri_exec_reconcile.py` remains
outside the closure as helper authority.

## 9. Phase 28 — is the operation sufficient for recovery?

Yes, once the entrypoint exists. The next checkpoint's scan —
`adapter_identity != null` and no CRES, then reconcile that exact CINV — needs
only what the module already provides: one CINV in, `final_absent` out, no
Runtime store mutation. No widening required.

`RUNTIME_STORE_MUTATED = NO`: the reconciler holds no store handle, allocates no
identity, and writes no record.

## 10. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 92/92 |
| `run-validation.sh` (full) | **PASS**, 117/117 |
| identity authority (new) | **PASS**, 5 cases |
| container reconciliation (G11-AQ) | **PASS** |
| launch helper, transition, quota, worker/backend | **PASS** |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

One assertion of mine needed correcting mid-write: it scanned the backing-store
example for the substring `uid`, which matches inside `filesystem_uuid`. It now
parses the JSON and checks keys. Fifth checkpoint running for that class of
mistake, and the fix is always the same — assert on structure, not on text.

## 11. Production non-mutation

No helper, sudoers, coordinator authority, runtime or generation installed. No
production Podman execution, no Fabric renewal, no CINV or CRES.
`/var/lib/kyri/capability` remains absent, `/etc/sudoers.d` holds only the
distribution README, and `/etc/kyri` is unchanged.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 12. Next

A ruling on §3: **where the execution identity is provisioned, and in what
record.** It is the smallest thing standing between here and a production
execution path — the reconciliation entrypoint needs it, the launch helper
should have had it since G11-AH, and every checkpoint after this one depends on
one or both.

With it settled: the entrypoint, then the supervisor, then coordinator-death
recovery and readiness, then CLI, preflight and Generation 13.
