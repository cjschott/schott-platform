# ENG-0005 G11-AO — adapter identity, interrupted semantics, and why the CLI still cannot execute

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `50773fc0c7ea589356aa19e1a37b43276add2a6b`
**Implementation commit:** `1bd4b2f`

Ruling B is implemented in full. `adapter_identity` is carried durably on the
invocation record before the adapter is entered, and §17's interrupted rule —
which G11-AN could not implement — is now decidable and implemented.

Ruling A is recorded as accepted: `result_artifact_reference` is `null` by
design, not by omission.

**The CLI work stopped, and not for the reason the brief anticipated.** It is
not that the CLI wants a caller-selected backend. It is that **the coordinator
cannot construct an execution binding at all** — the snapshot `create_argv`
requires lives in a root the coordinator has no write access to, by design.
The `adapter=` seam is a test seam; production execution goes through the
privileged transition. §10 has the evidence, and a second unresolved seam it
exposes.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none. Quick **89/89**, full **114/114**.

---

## 1. The G11-AN stop, and what it needed

Two entirely different situations wrote the same record: a preparation where no
adapter was ever authorised, and an execution that was authorised and then died
before its outcome became durable. Calling the first interrupted would libel it;
not calling the second interrupted would hide it.

## 2. Ruling A — result artifact storage, deferred

Accepted as ruled and recorded so the shape is not mistaken for an oversight.

For a successful execution: `result_digest` is **required** and present;
`result_artifact_reference` is **null**, and that is the architecture for this
increment. The immutable record carries no result body.

**The limitation, stated plainly.** Kyri can later prove that a candidate
result matches the recorded digest. It does **not** promise to retrieve the
result bytes from platform storage: they remain in the invocation's output leaf
as residue, reported and never cleaned. Anyone relying on historical retrieval
should read that sentence twice.

`RESULT_ARTIFACT_STORAGE = DEFERRED`,
`RESULT_ARTIFACT_REFERENCE = NULL_BY_DESIGN`.

## 3. Ruling B — adapter identity, and where it comes from

**It is accepted architecture, not new.** Capability Runtime design §14, line
671, lists the invocation record's conceptual fields:

> `payload_digest` · `effect_class` · `artifact_digest` · **`adapter_identity`** ·
> `requested_at` · `evidence`

It was in the design and absent from the implementation. This checkpoint adds
the field the design already named.

**Canonical value.** `profile.ADAPTER_IDENTITY` = `python-podman-v1`, the same
constant the profile, the worker's runtime-contract check and the backend
registry already use. No second spelling was introduced.

**A caller never supplies it.** It is derived from the execution binding the
runtime constructed — read from that binding's own authenticated profile, so
the identity recorded is the identity actually bound — and
`require_adapter_identity` refuses anything outside the governed vocabulary.
Two legal values: the governed identity, or `null` where no mechanism was
authorised.

## 4. Schema version

| Record | Before | After | Why |
| --- | --- | --- | --- |
| invocation | 1 | **2** | its closed field set gained `adapter_identity` |
| result | 2 | **2** | unchanged by this checkpoint |

Versions are per kind precisely so one may move without relabelling the other —
the split G11-AN made is what allows this. A corruption fixture that used
version `2` as its "unknown" value stopped corrupting the moment 2 became
correct, and now uses 99.

## 5. Ordering

```
verify governance
 → resolve and stage the package
 → establish the internal execution binding
 → determine the governed adapter identity        ← _bound_adapter_identity
 → write the immutable CINV, identity included    ← record_invocation
 → execute the adapter
 → conclude the outcome
 → write the CRES                                  ← record_terminal_result
```

The identity is determined **before** `record_invocation` and travels into it.
CINV is never patched afterwards; `CINV_MUTATED_AFTER_EXECUTION = NO`.

The ordering is the substance, not bookkeeping: once execution authority is
durably bound, the platform can no longer prove the adapter did not act, and
that is exactly what makes a missing result honestly *interrupted* rather than
merely unexplained.

## 6. The state model, implemented

| # | CINV | `adapter_identity` | CRES | Verdict |
| --- | --- | --- | --- | --- |
| 1 | prepared | `null` | absent | **sound** — nothing was authorised, nothing attempted |
| 2 | prepared | `python-podman-v1` | absent | **`execution-interrupted`** |
| 3 | prepared | `python-podman-v1` | present | **sound** — CRES is the authority for what happened |
| 4 | refused | `null` | present | **sound** — refusal keeps its own semantics |
| — | refused | `null` | absent | `refusal-without-result`, unchanged |
| — | prepared | `null` | present | **`result-without-execution-authority`** — a terminal outcome for an execution nobody authorised |

Two findings are named distinctly rather than sharing one word, because an
execution nobody can account for and a decision that was never written down are
different problems for an operator.

**The crash window stays open, deliberately.** Binding authority durably and
then dying before the adapter's first instruction reads as interrupted. A
mutable "started" bit would narrow it by introducing a second, weaker source of
truth about the same question — and the platform has never claimed exactly-once
execution (§17).

No repair, no synthesised result, no replay: the same `invocation_id` is still
refused as `invocation_identity_consumed`, and going forward means a new one.

## 7. Historical v1 records

`/var/lib/kyri/capability` does not exist — **zero production capability
records** — so there is no migration obligation. Verified read-only.

The policy that matters is what a v1 record *means*: it was written before the
field existed, so it carries no evidence about execution authority, and it is
therefore **never** classified as interrupted. Absence of a field is not
evidence of the thing the field would have recorded. Pinned by a test that
deletes the field and asserts the interrupted finding does not fire.

## 8. Succeeded, unregressed

Carried from G11-AN and re-proven through the real invoke path:

| Case | `reason` | `succeeded` |
| --- | --- | --- |
| completed with a trusted result | `completed` | **True** |
| completed with no result | `result-missing` | False |
| workload exit 42 | `provider-error` | False |
| timeout | `timeout` | False |
| adapter/profile failures | `adapter-error` | False |

## 9. Result artifact null tests

A successful CRES with `result_digest` set and `result_artifact_reference`
null is **valid**, and a non-null reference is not mandatory. A failure or
no-result CRES carries neither. The impossible pairings still refuse: an
admitted result without a digest, and a failure carrying one.

## 10. The CLI — the stop

Phase 16 asks the CLI to construct the governed adapter internally. It cannot,
and the reason is the privilege split working rather than a wiring gap.

`prepare_invocation` executes only when given an `execution_binding`, which
carries the argv from `create_argv(snapshot)`. That snapshot is materialised
into:

```
/run/kyri/execution-material   drwxrwx---  root:kyri-capability
```

The coordinator is `cschott` and **has no write access**. The handoff root it
*does* own (`/data/kyri/capability-handoff`, `cschott:cschott`) is the input
side; the snapshot is deliberately the worker's own copy, which is the anti-race
property G11-AL pinned.

So the coordinator cannot build an `ExecutionBinding` without doing the worker's
privileged job. **`adapter=`/`execution_binding=` are a test seam, not a
production path**, and the production route is:

```
CLI prepares (CINV, adapter_identity)
  → sudo kyri-exec-transition CINV-nnnnnn      ← privileged, and gated
      → worker → snapshot → backend → container
```

That gate is `SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`, which
depends on the helper ceremony, which is not this checkpoint's to run.

### The seam this exposes

Following it through raises a question the architecture has not answered. In
production the **worker** concludes the outcome, but the CRES store is
**coordinator-owned** (`--store-root` with `--expected-uid`). The worker cannot
write to it.

`protocol.py` names the mechanism — the worker reports `TERMINAL` and
`COLLECTED` to the coordinator over the inherited descriptors, and the
coordinator writes the CRES. The pieces exist. What does not exist is the
coordinator-side loop that runs the transition, reads that conversation, and
calls `record_terminal_result` with what it hears.

That is the real remaining work for a production invoke, and it is larger than
"wire the CLI". Naming it now beats discovering it during a ceremony.

`CLI_FULL_ISOLATED_INVOKE = NOT_RUN`, `CLI_NO_RESULT = NOT_RUN`, and
`CLI_CALLER_SELECTS_ADAPTER = NO` — no such flag exists and none was added.

## 11. Not built

- CLI execution binding and its E2E (§10).
- Preflight backend readiness (Phases 20–22).
- Generation-13 installer, fixture ceremony, recovery matrix (Phases 27–28).

The first is blocked as above. The other two are bounded work that was not
reached.

## 12. Generation 13

Recomputed mechanically. Unchanged:

| | |
| --- | --- |
| entry closure | **68 objects**, backend still naturally reachable |
| generation delta | **12** — 10 REPLACE, 2 CREATE |

The four modules this checkpoint touched — `records.py`, `evidence.py`,
`coordinator.py`, `inspection.py` — were already in the delta.

**Coherence groups.** Group A (worker entrypoint + backend) stands. The
result-plane group named in G11-AN now also governs *adapter-identity
interpretation*: `records.py` defines the field, `evidence.py` validates and
writes it, `coordinator.py` determines it, and `inspection.py` reads it to
classify interrupted. A split exposing the new coordinator against the old
inspection would write the field and never act on it — executing capabilities
while unable to classify an unresolved one. The whole generation installs
atomically, which satisfies the invariant; the group is named so a partial
install is recognised as the hazard it is.

`GEN13_ENTRY_CLOSURE = PASS`, `GEN13_PREINSTALL = NOT_READY` — no installer.

## 13. Helper and candidates

Unchanged and untouched. The installed helper is still `cfb0edd`-era on both
transition modules; source coherence stays pinned. The coordinator authority
candidate revalidates byte-identical at `3dec888c…2811`, and the sudoers grant
pins an entrypoint the helper ceremony does not change.

## 14. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 89/89 |
| `run-validation.sh` (full) | **PASS**, 114/114 |
| adapter binding and interrupted semantics (new) | **PASS**, 12 cases |
| terminal result contract | **PASS** |
| invoke execution E2E | **PASS** |
| capability runtime, inspection, preflight | **PASS** |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

**Three assertions moved.** Two carried a version literal. The third was mine
from G11-AN and was too blunt — it forbade the word "adapter" in a function
that legitimately calls `require_adapter_identity`, and now asserts on the call
that would actually matter. That is the fourth checkpoint running where a text
scan read a file's own vocabulary as the thing it forbids; this time I wrote
the bad assertion myself.

## 15. Production non-mutation

`/var/lib/kyri/capability` remains absent — no production capability records
exist and none were created. No production Podman storage opened, no workload
executed, nothing renewed. Fixture stores were shaped from production reads and
written only in temporary roots.

Not installed: worker entrypoint, backend, helper, sudoers, coordinator
authority, Generation 13. CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 16. Next operator action

None. The next step is engineering, and §10 changed its shape: before a
production invoke is possible, the coordinator needs a supervision path that
runs the transition, reads the worker's `TERMINAL`/`COLLECTED` conversation,
and records the result. That is the missing half of the production execution
route, and everything downstream — the CLI, preflight predictions, and the
first ceremony — sits behind it.

The deployment order is otherwise unchanged: coordinator authority, the
coherent cumulative helper, the worker/backend pair, Generation 13, and only
then the Fabric sequence.
