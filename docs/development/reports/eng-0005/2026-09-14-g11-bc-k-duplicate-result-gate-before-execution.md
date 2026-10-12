# ENG-0005 G11-BC-K — the duplicate-result gate moves in front of execution

**Checkpoint:** G11-BC-K (source correction; no production deployment)
**Date:** 2026-09-14
**Branch:** `arch/eng-0005-execution-transition`

The guard that refuses a second terminal result ran **after** the workload. A
re-execute of a resolved invocation would launch the privileged helper, run the
transition, create the container, transfer handoff ownership, run the provider,
dispose of the container — and only then decline to write the result down. An
execution that happened and was never recorded.

It now runs before any of that. Proven by measurement, not assertion: a
recording launcher shows the pre-fix code reaching the privileged-launch
boundary and the post-fix code reaching nothing.

Nothing was written to production. No Fabric or Trust write, no CINV or CRES
allocation, no `execute`, no `recover`, no Podman call.

---

## 1. The defect, traced

```
cli.command_execute
  store = CapabilityStore(...)                    # authoritative store, open
  record = store.read_record("capability-invocation", cinv)
  binding = supervised_binding(cinv)
  supervisor = ExecutionSupervisor(launcher, reconciler)
  └─ coordinator.execute_supervised
       ├─ outcome = supervisor.execute(binding)
       │    └─ supervision.py:344  child = self._launcher.launch(binding.cinv)
       │         ├─ privileged transition                 ── side effect
       │         ├─ container creation                    ── side effect
       │         ├─ handoff ownership transfer (fchown)   ── side effect
       │         ├─ provider start and execution          ── side effect
       │         └─ disposal / reconciliation             ── side effect
       └─ record_terminal_result(...)
            └─ evidence.py  with store.invocation_critical_section(...):
                 for existing in store.list_records(RESULT_KIND):
                     if invocation_record_id matches and attempt_number == 1:
                         raise  ← THE GUARD, here
```

```
DUPLICATE_RESULT_GUARD_CURRENT_LOCATION=
  tools/capability/evidence.py:record_terminal_result, inside
  store.invocation_critical_section -- reached only AFTER
  coordinator.execute_supervised has returned from supervisor.execute(binding)

PROVIDER_CAN_RUN_BEFORE_DUPLICATE_RESULT_REFUSAL=YES
```

`self._launcher.launch(binding.cinv)` is the **first statement** of
`ExecutionSupervisor.execute`. There is no check between the CLI opening the
store and that line.

### 1.1 A second fail-open in the same guard

`existing.get("attempt_number") == 1` means a result naming the invocation with
any other `attempt_number` — absent, `0`, `2`, a string — would **not** match,
and the guard would let the write through. `_result_body` hard-codes `1`, so no
correct writer produces another value; a damaged or hand-edited record does, and
that is exactly when the guard matters. Corrected below.

---

## 2. The invariant

> Once an invocation has a governed terminal result, another execute request for
> that CINV must refuse **before any provider-visible side effect**.

For CINV-000002 the refusal must precede helper launch, transition action,
container creation, provider start, handoff ownership mutation, and output
mutation. It must not allocate another CRES, touch CINV, write a lifecycle
transition, consume an attempt, or call reconciliation.

**The refusal:**

```
type    tools.capability.evidence.TerminalResultExists  (a CapabilityError)
message a terminal result already exists for CINV-000002
        (CRES-000001, outcome provider-error); this adapter performs one attempt
```

It names the result that closed the invocation, because an operator seeing this
needs to know which record did it. `command_execute` already maps
`CapabilityError` to `EXIT_DENIED` with the message on stderr and writes no
record, so the CLI contract needed no change.

---

## 3. The earliest trustworthy gate

`coordinator.execute_supervised`, immediately after the binding check and before
`supervisor.execute(binding)`.

It is the earliest point that holds both the authoritative store and the
`invocation_record_id`, and it is the function that owns the sequence — putting
the gate in `command_execute` instead would leave any other caller of
`execute_supervised` ungated.

**The lookup is by `invocation_record_id` against the CRES records themselves.**
Not a sequence scan, not an index, not the lifecycle journal, not container
presence, not the handoff, and nothing caller-supplied. This is the same key
`recovery.unresolved_invocations` already uses to decide what is resolved:

```python
resolved = {record.get("invocation_record_id")
            for record in store.list_records(RESULT_KIND)}
```

There was no existing shared reader to prefer — that set comprehension and the
recording guard were two separate spellings of the same question. There is one
now.

### 3.1 One reader, two callers

`evidence.existing_terminal_result(store, invocation_record_id)` is the single
authority. `require_no_terminal_result` wraps it for the gate, and
`record_terminal_result` calls that same wrapper inside the critical section.
Two spellings of "does a result exist" would eventually disagree, and the
disagreement would be a second execution.

**Both checks are kept, deliberately.** They answer different races: the gate
stops a second **run**; the guard inside the critical section stops a second
**record**, which two callers past the gate concurrently would otherwise both
reach.

### 3.2 It fails closed on a damaged result namespace

`list_records` **skips** a file that is not a mapping — right for listing, and
fail-open here: a corrupted `CRES` would simply vanish and the reader would
answer "no result" for an invocation that has one. So the reader counts the
`*.yaml` files in the result directory as well as reading them, and refuses on a
shortfall rather than stepping over it.

Three fail-closed conditions:

| condition | outcome |
| --- | --- |
| a result file is unreadable or is not a record mapping | refuse — *"N result record(s) are unreadable; whether CINV-… already has a terminal result cannot be established"* |
| more than one result names this invocation | refuse — *"N terminal results name CINV-…; the store is corrupt"* |
| a result names this invocation with any `attempt_number` | **blocks** — the number is reported, never used to dismiss |

---

## 4. RED before, GREEN after

The same probe, run against the pre-fix source (`HEAD`) and the corrected source.
It uses no symbol the fix introduced, so it is one measurement of two versions,
not two different tests. The launcher and reconciler are recording stubs that
perform nothing; `launch` raises the instant it is reached, which is already too
late.

**RED — pre-fix (`HEAD`):**

```
re-execute of a CINV that already has CRES-000001
  refusal            : AssertionError: stub launcher -- nothing real was started
  boundaries reached : ['PRIVILEGED HELPER LAUNCH: CINV-000002']
  VERDICT            : RED -- a forbidden boundary was reached before the refusal
```

The pre-fix code did not even refuse for the right reason: it died on the stub's
own assertion. On the real host that call is
`/usr/libexec/kyri-exec-transition`, and the container would have run.

**GREEN — corrected:**

```
re-execute of a CINV that already has CRES-000001
  refusal            : TerminalResultExists: a terminal result already exists for
                       CINV-000002 (CRES-000001, outcome provider-error);
                       this adapter performs one attempt
  boundaries reached : NONE
  VERDICT            : GREEN -- refused before any side effect
```

---

## 5. The matrix

`tests/test-capability-execution-duplicate-result-gate.sh` — 15 assertions,
unprivileged, temporary stores, no container. Every case asserts on the
**recorded call list**, so "refused" and "refused before anything ran" are
distinguishable.

| case | requirement | result |
| --- | --- | --- |
| A | `launch_authorized`, no CRES → may proceed | the gate passes it through to the launcher |
| B | final **successful** CRES → refuse before provider | `TerminalResultExists`, calls `[]` |
| C | final **provider-error** CRES → refuse before provider | `TerminalResultExists`, calls `[]` |
| D | malformed result linkage → fail closed | a non-mapping result file → refusal naming "unreadable", calls `[]` |
| E | CRES naming another CINV → must not block | CINV-000003 passes through with a CINV-000002 result present |
| F | two terminal results for one CINV → fail closed | refusal naming "corrupt", calls `[]` |
| G | result namespace claims what it cannot produce → fail closed | unparseable YAML → refusal, calls `[]` |
| H | unrelated later CRES → no false positive | CINV-000003 unaffected by CRES for -000001 and -000002 |

Plus: the refusal changes no record and allocates no second result; it does not
invoke reconciliation; a result with an unusable `attempt_number` (`None`, `0`,
`2`, `'one'`, `True`) still blocks; the recording guard still refuses inside the
critical section; and both callers go through the one reader.

---

## 6. CINV-000002

Modelled read-only from the **production record bytes**, copied into a fixture
store at `0400` — the digests below are the live ones:

```
modelled: CINV-000001.yaml 1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
modelled: CINV-000002.yaml 923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
modelled: CRES-000001.yaml 18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d

execute(CINV-000002): TerminalResultExists | boundaries: NONE
  "a terminal result already exists for CINV-000002 (CRES-000001,
   outcome provider-error); this adapter performs one attempt"
```

```
CINV_000002_REEXECUTE_PREEXEC_REFUSAL=PASS
```

Production was not invoked.

---

## 7. CINV-000003

Same store, plus a `launch_authorized` CINV-000003 carrying the G11-BC-J payload
digest `be85d58f…` and no CRES-000002:

```
execute(CINV-000003): boundaries: ['launch:CINV-000003']
```

The gate passed it straight through to the launcher — a legitimate first
execution is not blocked.

```
CINV_000003_FIRST_EXECUTION_ALLOWED_BY_GUARD=PASS
```

**This does not authorise production CINV-000003.**

---

## 8. Same-class sweep

Every call site that can start a provider, enumerated:

| site | before | after |
| --- | --- | --- |
| `coordinator.py:262` `supervisor.execute(binding)` — the supervised path, reached by `cli.command_execute` | **live wrong** | gated |
| `coordinator.py:172` `adapter.execute(execution_binding)` — the locally executed path in `prepare_invocation` | **latent wrong** | gated |
| `supervision.py:344` `self._launcher.launch(...)` | inside `supervisor.execute`; gated by its caller | — |
| `/usr/libexec/kyri-exec-worker.py:330` `.execute(execution)` | far side of the privilege boundary | not the same class |

```
SAME_CLASS_LIVE_WRONG=1
SAME_CLASS_LATENT_WRONG=1
```

**Why the locally executed path is latent, not live.** `command_invoke` supplies
neither `adapter` nor `execution_binding`, which is why every CINV carries
`adapter_identity: null`; no released caller reaches that branch. It is the same
defect regardless: normally the CINV there was just allocated and has no result,
but a **replayed** invocation identity resolves to an existing CINV, and that one
may already be resolved. Gated for one line.

**Why the worker is not the same class.** It has zero references to
`CapabilityStore` or the runtime store — verified by grep, and by design:
*"nothing on the far side of the boundary may write a Capability Runtime record,
and the worker could not — it has no store, no allocator and no path to one."*
It cannot host this gate, which is precisely why the gate must be
coordinator-side.

**Recovery and reconciliation are not the same class.**
`recovery.reconcile_unresolved` iterates `unresolved_invocations`, which
excludes anything with a CRES by construction, and calls the reconciler to stop
and remove containers — cleanup, never provider start.

No test or sample execution adapter carries the ordering defect; they are
fixtures driven by the suites, not entrypoints.

---

## 9. Deployment classification

```
DEPLOYMENT_REQUIRED=YES
DEPLOYMENT_CLASS=governed runtime generation (Generation 18), library-only.
  No helper ceremony. No execution-image change. No sudoers change.
```

Derived, not assumed. Both changed modules **are** installed governed bytes:

```
-r--r--r-- root:root /usr/lib/kyri/python/tools/capability/evidence.py
-r--r--r-- root:root /usr/lib/kyri/python/tools/capability/coordinator.py
```

A full comparison of all 46 installed modules under
`/usr/lib/kyri/python/tools/capability/` against the repo found **exactly two**
differences — the two this checkpoint changed. The Generation-18 baseline is
otherwise clean and the delta is two objects.

| object | predecessor (installed, = Generation 17) | successor |
| --- | --- | --- |
| `tools/capability/evidence.py` | `25f65bd345efc84faadfefff635d50b850df9362ae20130f47b55fc9cf8588b8` | `a571ad02ace56dbb93a5cc9385a4b2cca4e5c1922fa16bfa9f59848a25a386f6` |
| `tools/capability/coordinator.py` | `b72e7e2576095c96ffd5b4a3a48acc2fed7c1852b631a5f6f7d691e0bf8603c0` | `acb80cb93084b2b196d6b806b278128458be8947a9575eac7c7c509e9f045585` |

### 9.1 Coherence group

**One new group, both members, published together.** The two objects are
mutually dependent in one direction and silently degrading in the other:

- `coordinator.py` published **first** → it imports `require_no_terminal_result`
  from an `evidence.py` that does not define it, and **every** invocation fails
  with `ImportError` at module load.
- `evidence.py` published **first** → the new symbol exists and nothing calls
  it. Harmless; the host simply retains Generation-17 behaviour until the second
  object lands.
- `evidence.py` published and `coordinator.py` never → the gate exists and is
  never consulted. A host that looks corrected and is not.

So the publication order within the group is **`evidence.py`, then
`coordinator.py`**, and the group is not satisfied until both are at the
successor digest. A suggested name in the established style: **group G, "the
terminal-result gate"**.

Neither object is in `helpers.REQUIRED_HELPERS` — that surface is the eight
`/usr/libexec/kyri-exec-*` and `kyri_exec_*.py` objects, none of which move — so
`helpers.compatibility()` is unaffected and **no helper ceremony is required**.
Both objects are inside the execution closure reached from the production
execution roots (`coordinator.py` via `tools.capability.cli`, `evidence.py` via
`coordinator.py`), so no `OUTSIDE_EXECUTION_CLOSURE` exception is needed.

### 9.2 The declaration, which the platform demanded

Validation refused the branch, and correctly:

```
FAIL  the declared object tools/capability/evidence.py is a571ad02…,
      which is not a declared successor (25f65bd3…)
FAIL  the declared change at tools/capability/evidence.py is neither
      pending nor applied
FAIL  the declared object tools/capability/coordinator.py is acb80cb9…,
      which is not a declared successor (b72e7e25…)
```

`provisioning/execution/g5-preflight.sh` carries `GENERATION_DELTA`, and
`require_operator_source` refuses a declared object holding anything but a
declared successor. So a generation-declared runtime object **cannot be
corrected in the repository without a generation declaring the successor** —
the same rule that caught G11-BC-A. This was not anticipated when the
correction was written; the preflight found it.

Both rows now widen on both sides, exactly as at G11-BC-E: the Generation-17
digest moves into the baseline list (it is what the host has installed and is
therefore a legitimate predecessor to move **from**), and the new digest joins
the successor list (the reviewed bytes to move **to**). No check is relaxed, no
comparison becomes a wildcard, nothing is derived from git — four digests are
written down and every other byte sequence is refused exactly as before.

With the declaration in place, `test-capability-execution-g5-preflight.sh` and
`test-capability-execution-generation-succession.sh` both pass.

**The Generation-18 ceremony is not written in this checkpoint** and is not
authorised. §9 asked for the classification; the declaration is what makes the
classification durable rather than a claim in a report.

---

## 10. Terminal result semantics preserved

The correction is the **ordering** of the duplicate-result guard, not a
reinterpretation of a terminal provider failure. A first provider failure still
records exactly what G11-BC-I accepted, and the suite asserts it end to end
through the real `record_terminal_result`:

```
succeeded                   False
outcome_class               provider-error
reason                      provider-error
result_digest               None
result_artifact_reference   None
attempt_number              1
```

`disposal_proven` is a supervision-trace fact and is untouched — nothing in
`supervision.py` changed. CRES-000001 is unmodified.

The nine cases in `test-capability-result-contract.sh` and the terminal,
supervision, supervision-preconditions, recovery-discovery, result-content,
contract-outcome and invoke-preflight suites all pass unchanged.

---

## 11. Separate concerns

```
DURABLE_PROVIDER_DIAGNOSTICS_GAP=OPEN
BLOCKS_CINV_000003=NO
```

Not implemented here. The exit code and stderr are still captured by
`podman start --attach` and discarded, and `CRES` still has no field for either.
This correction touched neither `kyri_exec_podman.py` nor the result contract,
so the concerns stayed separate as instructed.

```
MAXIMUM_FABRIC_VALIDITY_POLICY=OPEN
BLOCKS_ENG_0005=NO
```

Deferred to its own architecture checkpoint, per the G11-BC-J ruling.

---

## 12. Production non-mutation

| | required | measured |
| --- | --- | --- |
| `CINV-000002.yaml` | `923ff0d7…` | unchanged |
| `CRES-000001.yaml` | `18ba4c34…` | unchanged |
| CINV sequence | 2 | 2 |
| CRES sequence | 1 | 1 |
| new CINV / CRES | none | none |
| Fabric aggregate | `3fa32b83…` | unchanged |
| Trust aggregate | `53605e4e…` | unchanged |
| installed runtime | Generation 17 | unchanged — the corrected bytes are in the repo only |

No `execute`, no `recover`, no Podman invocation. Every rehearsal ran in a
temporary directory; the only production data read was the three record files in
§6, read-only and copied.

The corrected source is **not installed**. The host remains at Generation 17 and
therefore still carries the defect — which is why CINV-000003 stays blocked
until Generation 18 is deployed and accepted.

---

## 13. Next

**G11-BC-L — the Generation-18 ceremony**: prepare the governed runtime
generation for the two-object group in §9, in the established shape
(fixture-proven matrix, interruption recovery at each publication boundary,
coherence gate), then deploy and accept it.

Only after that is accepted do the four G11-BC-J Fabric freeze blocks run — the
renewal starts a four-day clock and should be spent on an invocation that is
actually permitted to execute. Then CINV-000003 Stage 1 with the Option B
payload (`be85d58f…`).

Still prepared and unauthorised, independent of all of this: the G11-BC-G
evidence remediation.
