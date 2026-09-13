# ENG-0005 G11-BC-I — CRES-000001: the provider ran, and refused the payload

**Checkpoint:** G11-BC-I (root cause; no production change)
**Date:** 2026-09-13
**Branch:** `arch/eng-0005-execution-transition`

The second Stage-3 execution of CINV-000002 completed through the governed
execution boundary and recorded `CRES-000001` with `outcome_class:
provider-error`. This is not the previous unresolved failure: the boundary
worked, the container ran, disposal was proven, and the platform wrote exactly
one terminal record.

**The capability refused the payload.** The governed payload asked for
`operation: "execute"`. The capability performs `verify-execution-boundary`. It
wrote `refused: the payload requests an operation this capability does not
perform` to stderr and exited 1. The container's nonzero exit is what
`provider-error` means.

Nothing was executed, recovered, allocated or mutated this checkpoint.

---

## 1. `provider-error`, traced backwards

```
PROVIDER_ERROR_ORIGIN=
  tools/capability/execution/lifecycle.py:_disposition ->
    TerminalDisposition.COMPLETED_NONZERO
  tools/capability/execution/lifecycle.py:_OUTCOME[COMPLETED_NONZERO]
    = "provider-error"
```

There is exactly one source of the label. `_OUTCOME` is a closed dict and
`COMPLETED_NONZERO` is its only key that maps to `provider-error`
(`lifecycle.py:276`). Reaching it requires **all** of:

```python
not timed_out                       # not TIMED_OUT
not _contradicted(observed)         # not INTEGRITY_FAILURE
observed.started_proven             # not NEVER_STARTED
observed.exit_code_trustworthy      # not UNTRUSTWORTHY_EXIT
observed.state in ("exited","stopped")   # not RUNNING
observed.exit_code != 0             # not COMPLETED_ZERO
```

and `started_proven` is itself `bool(started_at) and state not in (None,
"created")` — the runtime saying the container ran, never an exit code being
present.

```
PROVIDER_ERROR_TRIGGER=
  the governed container reached state "exited" with a proven start
  (started_at present) and a nonzero exit code
```

The label was therefore **earned by observation, not defaulted**. Two further
consequences follow mechanically and matter below:

- `may_collect_result = disposition is COMPLETED_ZERO` → **False**, so the
  collector never read the output tree for a result. `result_digest: null` and
  `result_artifact_reference: null` are that, not a second failure.
- `TerminalClassification.succeeded` is hard-coded `False` at this stage;
  success needs an admitted result, which T14 owns.

---

## 2. What was executed, reconstructed

From `CINV-000002.yaml`, the launch authorisation, the published handoff
profile, and the installed Generation-17 source (`worker.create_argv`,
`kyri_exec_podman.py`). Nothing was re-run to obtain this.

| | |
| --- | --- |
| image | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` (`--pull=never`) |
| interpreter | `/usr/bin/python` (`worker.CONTAINER_INTERPRETER`, adapter-owned) |
| entrypoint arg | `/kyri/package/main.py` (`_container_entrypoint`, from `package_entrypoint: main.py`) |
| container command | `/usr/bin/python /kyri/package/main.py` — no image `ENTRYPOINT` override |
| uid:gid | `65532:65532`, via `--userns keep-id:uid=65532,gid=65532` |
| environment | exactly four: `LC_ALL=C.UTF-8`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONHASHSEED=0`, `PYTHONUTF8=1` |
| network | `none`; `--cap-drop ALL`; `--security-opt no-new-privileges`; `--read-only`; `--read-only-tmpfs=false` |
| limits | `--pids-limit 64`, `--memory 256m`, `--memory-swap 256m`, `--cpus 0.5`, tmpfs `/tmp:size=16m,mode=1777,nodev,noexec,nosuid` |
| working directory | not set on the container; the *host-side* Podman process runs at `/` (`SAFE_WORKING_DIRECTORY`) |
| mounts | `/kyri/package` ro; `/run/kyri/input/payload` ro; `/kyri/output` rw |
| payload path | `/run/kyri/input/payload` — 254 bytes, `e2914a90…` |
| package path | `/kyri/package/main.py` — 8192 bytes, `683e25ed…` |
| output path | `/kyri/output`, bound to the handoff `out/` leaf |
| start | `podman start --attach`, so the call returns only when the workload has terminated |

### 2.1 The ownership question, and why it is not the answer

The handoff `out/` is `kyri-capability:kyri-capability` (999:987) mode 0700
while the profile's `execution_uid` is 65532. That looks like an unwritable
output directory, and it is not: `--userns keep-id:uid=65532,gid=65532` maps the
invoking worker onto container uid 65532, so the worker-owned 0700 directory
appears inside as owned by the governed container identity and is writable by
it. `worker.create_argv` says so explicitly, and records that the alternative
(`U=true` on the bind) was rejected because it makes the write succeed and the
collection fail.

The Generation-17 ownership correction did what it was built to do. The empty
`out/` has a different cause.

### 2.2 Expected provider protocol

`main.py` (which is also the whole of CAPDEF-0001 and CCON-0001) reads one field
from the payload, `operation`, and requires it to equal
`verify-execution-boundary`. On agreement it writes
`/kyri/output/result.json` — `O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0444`, fsynced —
and returns 0. On any refusal it writes `refused: <reason>` to stderr, writes
**nothing**, and returns 1.

Its own docstring states the design: *"There is no way to report a failure inside
a result… so a refusal writes nothing and returns nonzero. The lifecycle reports
it, the document never does — which is also why a capability cannot self-declare
success."*

---

## 3. The governed artifact, recomputed

| | |
| --- | --- |
| `package/main.py` SHA256 | `683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd` |
| size | 8192 bytes — matches the Stage-2 evidence |
| package tree SHA256 | `6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e` |
| governed digest (profile `package_digest`) | `6f2282c5…` — **match** |
| governed digest (CINV `artifact_digest`) | `sha256:6f2282c5…` — **match** |
| manifest `package_tree_sha256` | `sha256:6f2282c5…` — **match** |
| vs. reviewed source authority | `diff` against `packages/kyri-execution-boundary-verification/1.0.0/main.py` — **byte-identical** |

The deployed provider is exactly the reviewed, governed artifact. **It is not a
package defect.**

---

## 4. Did the provider run?

```
PROVIDER_STARTED=YES
```

Proven three ways, none of them the label:

1. **The classification could not have been reached otherwise.** `provider-error`
   requires `started_proven`, which requires the runtime to report a
   `started_at` and a state other than `created`. A container that never ran
   classifies `NEVER_STARTED` → `adapter-error`.
2. **CRES-000001 carries the timestamps.** `started_at
   2026-09-13T12:57:47.371750807-05:00`, `ended_at …:47.542056629-05:00` — a
   **170.3 ms** run, copied from the lifecycle observation. Too long for a
   container that never started; consistent with a Python interpreter reading
   254 bytes and refusing.
3. **The reproduction** (§7) produces the same refusal in the same shape.

```
PROVIDER_EXIT_CODE=nonzero (proven); 1 (reproduced, not durably recorded)
PROVIDER_STDOUT=empty -- main.py writes to stdout on no path
PROVIDER_STDERR="refused: the payload requests an operation this capability
                 does not perform" -- reproduced, not durably recorded
```

### 4.1 Why the exact exit code and stderr are not durable

They are captured and then discarded. `kyri_exec_podman.py` runs `podman start
--attach` with `capture_output=True`, `check=False`, and **does not read the
result**: a nonzero workload exit is deliberately not treated as a backend
failure, and the exit code is re-read from the container's own state instead.
`logs` is not in `PERMITTED_SUBCOMMANDS`. The adapter's `COLLECTED` message
carries `stdout_truncated=False, stderr_truncated=False` — fields for a capture
that never happens. The exit code itself reaches the coordinator on the
`TERMINAL` protocol message but is not written to `CRES`, whose `RESULT_FIELDS`
have no slot for it. The container was then disposed of.

So this checkpoint had to *reproduce* the diagnostic rather than read it. That
is a real observability gap and it is recorded in §12 as a finding, not folded
into the root cause.

---

## 5. The empty `out/`

```
OUTPUT_REQUIRED_FOR_SUCCESS=YES
EMPTY_OUTPUT_CAUSED_FAILURE=NO
```

Output *is* required: `AdapterOutcome.succeeded = result is not None`, and
`collector.read_result` refuses a tree with no root-level `result.json`
(`collector.py:229`). A run with no result cannot succeed.

But the empty directory did not cause this failure and could not have. The
disposition was already `COMPLETED_NONZERO` before collection, and
`may_collect_result` is False for it — so the collector's verdict was never
consulted. Had `result.json` been present, the outcome would still have been
`provider-error`. The empty `out/` is the *same* fact as the nonzero exit seen
from the other side: `main.py` refused before `write_result` was reached.

`_collect` did still walk the tree (*"a failed execution's output is still
evidence"*), and found nothing.

---

## 6. The provider protocol contract, in the source's own words

Success requires **all three**, and they are checked in three different places:

1. **exit code 0** — `lifecycle._disposition` → `COMPLETED_ZERO`, the only
   disposition with `may_collect_result=True`
2. **a root-level `/kyri/output/result.json`** — `collector.read_result`,
   `RESULT_NAME`
3. **that document satisfying the closed content schema** —
   `result_content.validate_result_content`: exactly the five fields
   `capability`, `operation`, `payload_digest`, `result_schema_version`,
   `checksum`; `capability` must be `kyri-execution-boundary-verification`;
   `operation` must be in `OPERATIONS = ("verify-execution-boundary",)`;
   both digests lowercase hex SHA-256

There is no JSON-on-stdout channel. Stdout is not read at all.

### 6.1 The actual terminal vocabulary

`records.OUTCOME_CLASSES`:

```
completed  refused  adapter-error  provider-error  timeout
cancelled  interrupted  serialisation-failure
```

Selected by `lifecycle._OUTCOME`, keyed on disposition:

| disposition | outcome class | when |
| --- | --- | --- |
| `NEVER_STARTED` | `adapter-error` | start not proven |
| `RUNNING` | `interrupted` | still running when asked |
| `COMPLETED_ZERO` | `completed` | proven start, exited, exit 0 |
| `COMPLETED_NONZERO` | **`provider-error`** | proven start, exited, exit ≠ 0 |
| `UNTRUSTWORTHY_EXIT` | `adapter-error` | exit code present but not trustworthy |
| `TIMED_OUT` | `timeout` | wall threshold (30 s) reached first |
| `INTEGRITY_FAILURE` | `adapter-error` | the report contradicts itself |

Plus `refused` (a pre-execution governed negative) and `serialisation-failure`
(result bytes that would not admit). `cancelled` is in the vocabulary and is
emitted by nothing — `contract_outcome.UNREACHABLE_OUTCOME_CLASSES` names it so
its absence is a checked fact.

`completed` with no admitted result gets `reason = result-missing`
(`records.REASON_RESULT_MISSING`) — the case that used to read as success.

Through a contract, `contract_outcome.CONTRACT_FAILURE_MODE` maps
`provider-error → adapter-error`, deliberately: a caller cannot distinguish "the
capability's process died" from "the machinery could not serve the call".

**Four of the terms in the checkpoint request do not exist in this source:**
`contract-error`, `worker-refused`, `successful-no-artifact` and
`successful-with-artifact` appear nowhere. The nearest real spellings are
`serialisation-failure`, the `SupervisionRefused` path (which writes no record
at all), `completed` + `result-missing`, and `completed` + an admitted digest.

---

## 7. RED reproduction

Off production, in a temporary directory, with the **exact** governed bytes
copied from the handoff (`main.py` `683e25ed…`, payload `e2914a90…`), the two
mount constants re-rooted onto the fixture and nothing else changed, run under
the adapter's own four environment variables and nothing else:

```
refused: the payload requests an operation this capability does not perform
exit_code=1
output tree: empty
```

```
RED_REPRODUCTION=PASS
```

Same message, same exit code, same empty output tree as production.

GREEN, with one field changed and the rest of the document byte-identical:

```
operation: "verify-execution-boundary"     (272 canonical bytes, 4257f93b…)
exit_code=0
/kyri/output/result.json   0444   281 bytes
  {"capability":"kyri-execution-boundary-verification",
   "checksum":"ee868498…","operation":"verify-execution-boundary",
   "payload_digest":"4257f93b…","result_schema_version":1}
```

The result validates against `result_content.validate_result_content`.

A containerised reproduction was **not** run. It would require privilege into
the governed execution identity's rootless Podman store, which is the
manipulation this checkpoint forbids, and it would add nothing: the image
contributes only the interpreter, and the refusal is in `main.py`'s own control
flow at a point reached before any mount is written.

---

## 8. Defect ownership

```
DEFECT_CLASS=PAYLOAD_CONTRACT_DEFECT

ROOT_CAUSE=
  The governed payload for CINV-000002 sets operation="execute", which is the
  FABRIC SCOPE verb from CINST-000004.effective_scope.permitted_operations. The
  field main.py reads carries the CAPABILITY vocabulary, whose only member is
  "verify-execution-boundary" (result_content.OPERATIONS). main.py raises
  VerificationRefused, writes no result, and returns 1; the container exits 1;
  lifecycle classifies COMPLETED_NONZERO -> provider-error.
```

Two closed vocabularies share one field name and no members:

| vocabulary | value | declared in | checked by |
| --- | --- | --- | --- |
| Fabric scope | `execute` | `CINST-000004.effective_scope.permitted_operations` | `fabric_evidence.evaluate` against the scope |
| capability | `verify-execution-boundary` | `result_content.OPERATIONS` | `main.py`, and again by the collector on the result |

`--operation execute` on the `invoke` command was **correct**: `verify-execution-
boundary` would have been refused by the scope gate as
`operation-not-permitted-by-scope`. The mistake was carrying that value into the
payload document, where a different vocabulary applies.

### 8.1 Why nothing caught it earlier

`payload.py`'s closed schema types `operation` as `_Field(kind=str,
required=True)` — free text, no enum, no cross-check against the capability. It
is closed against *unknown fields*, not against wrong values. Nothing between
the operator's editor and the container examines whether the requested operation
is one the capability performs, so the earliest possible detection point was
inside the container, four days and one spent invocation identity later.

That is a real gap. It is **not** classified as the root cause, because closing
it needs authority that does not exist: no Fabric record declares a capability's
operation vocabulary — CAPDEF-0001 has no such field — so the coordinator has
nothing to check against. Adding one is a design decision for a later
checkpoint, not a bug fix for this one.

---

## 9. Was the platform's behaviour correct?

```
TERMINAL_RESULT_MODEL_CORRECT=YES
LIFECYCLE_WITHOUT_TERMINAL_TRANSITION_INTENTIONAL=YES
```

Every element of the observed behaviour is the specified one:

| observed | authority |
| --- | --- |
| `CRES-000001` allocated once | `evidence.record_terminal_result`, inside `store.invocation_critical_section` |
| `succeeded=false` | `AdapterOutcome.succeeded = result is not None`; no result was admitted |
| `reason=provider-error` | `reason = outcome_class` for any non-`completed` class |
| `result_digest=null`, `result_artifact_reference=null` | enforced: *"a result that was not admitted may not carry a digest or a reference"* |
| `disposal_proven=true` | the supervision trace; no `kyri-CINV-*` container remains |
| `CINV` unchanged | *"It never touches the invocation record"* — CINV is immutable pre-execution evidence |
| `rc=1` | `command_execute` returns `EXIT_SUCCESS if terminal.succeeded else EXIT_DENIED` |

**Why the transition journal stops at `launch_authorized`.** `LifecycleState`
declares twelve states through `RELEASED`, but the journal is written by
`authorise_launch` *before the privilege boundary is crossed* and is immutable
thereafter. The states past `launch_authorized` are worker-side protocol states;
they exist on the wire, and the coordinator — which has no Podman authority and
must not gain any — cannot witness them.

The journal is not the outcome record. It exists so `recovery.unresolved_
invocations` can find a supervised invocation that lost supervision: *"an
invocation at or beyond `launch_authorized` with no terminal result is one where
execution was authorised and its outcome was never established."* Resolution is
determined by the **presence of a CRES**, not by a transition. Now that
CRES-000001 exists, CINV-000002 is in that function's `resolved` set and is
correctly no longer enumerated — which is also why `recover` would find nothing
and was not run.

So the split is deliberate and coherent: the journal is the pre-boundary
authorisation trail, `CRES` is the terminal outcome, and `CINV` is immutable
attempt evidence. Not a defect.

---

## 10. CINV-000002 finality

```
CINV_000002_FINAL_CLASSIFICATION=SPENT_AND_RESOLVED (terminal, one attempt performed)
CINV_000002_EXECUTE_AGAIN_ALLOWED=NO
CRES_000001_FINAL=YES
```

`evidence.py:310–315`, inside the invocation critical section:

```python
for existing in store.list_records(RESULT_KIND):
    if (existing.get("invocation_record_id") == invocation_record_id
            and existing.get("attempt_number") == 1):
        raise CapabilityError(
            f"a terminal result already exists for {invocation_record_id}; "
            f"this adapter performs one attempt")
```

`CRES-000001` carries `invocation_record_id: CINV-000002` and `attempt_number:
1` (hard-coded in `_result_body`; there is no second-attempt path). A second
result for CINV-000002 is therefore impossible, and `CRES-000001` is final —
records in this store are write-once and nothing rewrites a result.

### 10.1 A finding: the guard is after the execution, not before it

`command_execute` reads the CINV, builds the binding, and calls
`supervisor.execute(binding)` **before** `record_terminal_result` ever looks for
an existing result. There is no pre-execution gate keyed on a CRES. So a second
`execute CINV-000002` would create and run the governed container again — a real
side effect, a real disposal — and only then refuse to record, leaving an
execution that happened and was never written down.

The answer to "may it be executed again" is therefore **NO** on stronger grounds
than the duplicate guard: the guard protects the *record*, not the *host*. This
is logged in §12 as a latent defect. Nothing in this checkpoint touches it.

---

## 11. The next invocation

```
NEXT_CINV=CINV-000003
NEXT_CRES=CRES-000002
FABRIC_RENEWAL_REQUIRED_BEFORE_NEXT_INVOKE=YES
```

Sequence counters read (not allocated): `capability-invocation.seq = 2`,
`capability-result.seq = 1`.

**The Fabric chain is expired, and this was measured rather than assumed:**

| record | field | value | status on 2026-09-13 |
| --- | --- | --- | --- |
| CADV-000005 | `valid_until` | `2026-09-10T21:30:00-05:00` | **expired** (3 days) |
| CINST-000004 | `admitted_until` | `2026-09-10T21:30:00-05:00` | **expired** (3 days) |
| CROUTE-0004 | — | route version 4 | no expiry field |
| CSEL-000003 | `selected_at` | `2026-09-09T06:10:00-05:00` | selects the expired CINST-000004 |

`eligibility._advertised` requires `observed_at <= instant < valid_until` and
otherwise reports `REASON_ADVERT_STALE`. An `invoke` today would be refused
before reaching any payload.

Both the advertisement and the instance admission have lapsed, so the renewal is
the same supersession shape as CADV-000004→000005 / CINST-000003→000004: a new
advertisement, a new instance admitted against it, and a new selection. Fabric
sequences currently read advertisement 5, instance 4, route 4, selection 3.
**None of these were allocated.**

The corrected payload — `operation: "verify-execution-boundary"`, everything
else byte-identical — has canonical digest
`4257f93b90a4e51702866bac2f5e5a64c5a62f019c0c357b7d377be858fd31df` over 272
bytes. Because `payload_digest` is bound into the invocation record, and
CINV-000002 is immutable and spent, the corrected payload can only be carried by
a new CINV.

---

## 12. Same-class sweep

```
SAME_CLASS_LIVE_WRONG=1
SAME_CLASS_LATENT_WRONG=1
```

Every `"operation": "<value>"` payload document in the tree was enumerated. All
except two are Fabric-plane request documents (`register-advertisement`,
`admit-instance`, `create-route`, `select`, `create-decision`) where `execute`
does not appear and the vocabulary question does not arise. The two capability
payloads are:

| where | value | state |
| --- | --- | --- |
| the published handoff for CINV-000002, and the reviewed document in `2026-09-09-g11-bb-x-…:263` | `execute` | **live wrong** — executed, refused, CINV spent |
| the reviewed document in `2026-09-04-g11-bb-a-…:307` (CINV-000001) | `execute` | **latent wrong** — CINV-000001 never reached Stage 3 |

No execution-image entrypoint, result protocol adapter or test fixture carries
the defect. Two candidates were examined and cleared rather than skipped:
`tests/test-capability-supervised-execution-e2e.sh:134` writes a payload
`{"operation": "execute"}`, but the `main.py` it pairs with is a stub the test
supplies and never reads the field — there is no operation contract to violate;
and the `"operation": "execute"` in the helper-ceremony suites is an
*invocation-record* fixture field (Fabric plane), where `execute` is correct. `tests/test-capability-execution-verification-package.sh` already
proves the package refuses a payload requesting another operation
(`verify-something-else`, `''`, `VERIFY-EXECUTION-BOUNDARY`, and a trailing-space
variant) — the package behaviour was correct and tested. What was untested was
the *shipped ceremony payload* against that vocabulary. §13 closes that.

### 12.1 Two separate findings, not folded into the root cause

- **No durable provider diagnostic.** §4.1. Exit code and stderr are captured
  and discarded; `CRES` has no field for either. Diagnosing a provider failure
  requires reproducing it. Not a cause of this failure; a cost of it.
- **The duplicate-result guard runs after execution.** §10.1. A re-execute would
  run the container and then refuse to record.
- **Succession staleness, fifth recurrence.** §13.1. Corrected in this
  checkpoint because it went red; the class itself remains open.

Both are outside this checkpoint's authority to fix and are recorded so they are
decisions rather than oversights.

---

## 13. Correction

```
DEPLOYMENT_REQUIRED=NO
DEPLOYMENT_CLASS=none -- no governed package bytes, no execution image, and no
  installed runtime change. The correction is one field of the operator payload
  document at the next invocation ceremony, which is new ceremony data and not
  a deployment of anything.
```

The package is byte-identical to its reviewed authority; the image is the
governed one; the runtime behaved to specification. There is nothing to deploy.

What the repository gains is the guard that would have caught it:
**`tests/test-capability-execution-payload-operation-contract.sh`** — 10
assertions, unprivileged, fixture-only, no store or handoff or container.

| section | proves |
| --- | --- |
| A | the reviewed document in the suite canonicalises to `e2914a90…` over 254 bytes — i.e. it **is** the bytes CINV-000002 carried, not a paraphrase of them; and the package under test is the one the manifest governs |
| B | **RED** — the governed package refuses those exact bytes with that exact message, writes no result, leaves the output directory empty, and `main()` returns 1 |
| C | **GREEN** — the same document with `verify-execution-boundary` returns 0 and writes a `result.json` that passes `validate_result_content`; and that `operation` is the *only* field that differs |
| D | `execute` is not in `result_content.OPERATIONS`; the coordinator's payload schema **accepts** the defective document and reproduces its governed digest; the capability is the only thing that refuses it |
| E | the suite left the governed package tree with no compiled member — it loads the entrypoint with `sys.dont_write_bytecode` set, because a `__pycache__` beside it is a member the package contract refuses and would change the tree digest of the artifact under test |

Section D is the one that matters for the next ceremony: it states the gap as a
checked fact. If a future release does constrain the payload's operation, that
case fails and the next author has to decide deliberately.

Registered in `tools/dev/run-validation.sh` (`TOTAL_STEPS` 113→114 quick,
138→139 full) and `.github/workflows/ci.yml`. Not host-only — it reads only
committed files.

### 13.1 A second correction the checkpoint forced: succession staleness, again

Validating the above turned `tests/test-capability-execution-bc-e-helper-
ceremony.sh` **red**, at its host-only case *"the shipped result history is
exactly the live store (both empty)"*. Nothing in this checkpoint caused it.
CRES-000001 did, when Stage 3 wrote it.

This is the **fifth** recurrence of the succession-staleness class, with a twist
the previous four did not have: the stale thing is correct. The G11-BC-E
ceremony has been executed and accepted, so `ACCEPTED_RESULT_HISTORY=()` is now
a *historical statement of what its reviewer looked at*, and the live store
legitimately moved past it. The two ways to make the suite green were:

- edit the spent ceremony's declaration to name CRES-000001 — which falsifies
  its record of its own review, and re-arms a completed ceremony against a host
  state nobody reviewed. **Rejected.**
- fix the assertion, which was asking the wrong question.

The case conflated *"was the declaration true when it was reviewed?"* — the
defect it was built for, where G11-BC-E's declaration described a different
ceremony's review — with *"is it still current?"*, which the ceremony's own
runtime gate answers by refusing (`the invocation history has moved past the
reviewed one … re-review before installing`).

So the comparison is now a **prefix**: every record the declaration names must
still exist with the digest it named, and the store may have grown. A wrong
digest still fails at its own position and a vanished record still fails
outright, so the original defect is still caught. The counter check becomes
`>=` for the same reason, and a new case reports how far production has actually
advanced (`2 invocation(s)/1 result(s) against the reviewed 2/0; it has only
grown`) so a green run states the drift instead of hiding it.

**The strictness was not dropped, and was not restated either.** Two existing
fixture cases already drive this ceremony against a store that moved past its
declaration and require the refusal by name — once through the gate and once
through `--verify`. Adding a third assertion that re-runs the *production*
ceremony against the real host would have proven nothing new and would have made
this suite invoke a spent ceremony to do it.

---

## 14. Production non-mutation

Measured read-only this checkpoint:

| item | value | required | |
| --- | --- | --- | --- |
| `CINV-000002.yaml` | `923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa` | `923ff0d7…` | ✔ |
| `CRES-000001.yaml` | `18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d` | `18ba4c34…` | ✔ |
| `capability-invocation.seq` | 2 | 2 | ✔ |
| `capability-result.seq` | 1 | 1 | ✔ |
| transitions for CINV-000002 | `reserved`, `launch_authorized` — 2 files, unchanged | — | ✔ |
| mutations | last is `CMUT-000000000006` (the launch authorisation) | — | ✔ |
| handoff `package/main.py` | `683e25ed…`, `0444` | — | ✔ |
| handoff `payload` / `profile` | `e2914a90…` / `b707d433…` | — | ✔ |

No `execute`, no `recover`, no `podman` invocation of any kind. No Fabric, Trust,
sudoers, handoff, evidence or runtime mutation. No CINV or CRES allocated. The
reproduction ran entirely inside a scratch directory on copies.

`PRODUCTION_MUTATION=NONE`

---

## 15. Next checkpoint

The provider defect is understood and needs no code or artifact deployment. What
stands between here and a green production invocation is Fabric renewal, and
that is an operator ceremony this checkpoint is not authorised to prepare.

Recommended next: **G11-BC-J — Fabric chain renewal preparation**, producing the
reviewed supersession ceremony for a new advertisement and instance admission,
the selection on it, and the corrected payload document
(`operation: verify-execution-boundary`, canonical digest `4257f93b…`) for
CINV-000003 — prepared and unexecuted, in the usual shape.

The G11-BC-G evidence remediation (`--verify`/`--apply`) remains prepared and
unauthorised; it is independent of this and blocks nothing.
