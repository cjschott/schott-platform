# ENG-0005 G11-W — Pre-Invoke Operation Authority and Scope Enforcement Audit

- Checkpoint: ENG-0005 G11-W
- Date: 2026-08-28 (local date at report creation; midnight was not crossed)
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `06ead73e8b70d0a652b914c0d13b69e0cc353adc`
- Host: `schai`
- Result: `ACCEPTED` (audit; no production mutation)
- **Primary conclusion: `PRE_INVOKE_AUTHORITY=B_GAP`**

## 1. Starting authority and the current governed chain

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `06ead73e8b70d0a652b914c0d13b69e0cc353adc` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-V report present | yes |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Generation 11 runtime | 57 `.py` files, unchanged |
| Root Authority | unmounted |

Production: CADV 3, CINST 2, CROUTE 2, **CSEL 1**, `capability-selection.seq = 1`.
`CSEL-000001` selected `CINST-000002` via `CROUTE-0002`; route head `CROUTE-0002`;
`CINST-000002` `admitted`; `CADV-000003` the advertisement head.

## 2. Remaining binding lifetime

```
audit instant   2026-08-28T21:34:05-05:00
expiry          2026-08-30T16:19:19-05:00
remaining       1 day, 18:45:14
```

## 3. The complete post-selection execution path

Traced mechanically across the whole repository, not just `tools/fabric/`.

```
CSEL-000001  (persisted capability-selection)
   ↓  claimed by an operator as --selection-id
capability/cli.py::command_invoke
   ↓
capability/coordinator.py::prepare_invocation
   ├─ capability/fabric_evidence.py::verify_selected_evidence   ← the authority bridge
   ├─ capability/package_resolution.py::resolve_and_stage_package
   ├─ capability/invocation_identity.py::bind
   └─ capability/evidence.py::record_invocation      → CINV, status `execution-prepared`
   ↓  (adapter is never supplied by the CLI — see §3.2)
   └─ returns reason `no_authorised_adapter`, EXIT_DENIED
   ↓
capability/cli.py::command_authorise_launch  --cinv --cimp     ← a SEPARATE command
   ↓
capability/execution/authorisation.py::authorise_implementation  (CIMP → profile)
   ↓
capability/execution/launch.py::authorise_launch
   ├─ lifecycle RESERVED → LAUNCH_AUTHORIZED  (the authority)
   ├─ launch_record(...)  seven fields
   └─ handoff: members `payload`, `profile`
   ↓
privileged transition (kyri_exec_transition.py, kyri_exec_transition_action.py)
   ↓
capability/execution/worker.py  → execve
```

### 3.1 Layer-by-layer

| Layer | Input authority | Consumes CSEL | Consumes CINST | Carries operation | Checks operation | Reads `effective_scope` | Consults Trust | Contract/package authority | Failure behaviour |
|---|---|---|---|---|---|---|---|---|---|
| `command_invoke` | CLI args + approved payload | claimed only | claimed only | **no** | no | **no** | no | no | `_Unusable` / EXIT_DENIED |
| `prepare_invocation` | delegates | via bridge | via bridge | **no** | no | **no** | no | via bridge | returns durable decision |
| `verify_selected_evidence` | Fabric C8 read-only | **yes** | **yes** | **no** | **no** | **no** | **no, explicitly** | yes — CCON, CPKG, CAPDEF equality | named refusal |
| `resolve_and_stage_package` | package + approved artifact root | no | no | no | no | no | no | package digest/manifest | refusal |
| `record_invocation` | evidence + staging | carries id | carries id | no | no | no | no | no | durable record |
| `command_authorise_launch` | `--cinv`, `--cimp` | **no** | **no** | **no** | no | **no** | no | no | EXIT_DENIED |
| `authorise_implementation` | CIMP admission | no | no | no | no | no | no | no | `IncompatibleImplementation` |
| `authorise_launch` | CINV lifecycle | no | no | no | no | no | **no, explicitly** | no | `LaunchRefused` |
| handoff / transition / worker | launch record + handoff | no | no | no | no | no | no | no | fail-closed on digests |

### 3.2 Two facts that bound the exposure

**The released `invoke` CLI cannot execute.** `prepare_invocation` executes only when
**both** `adapter` and `execution_binding` are supplied:

```python
if decision.status == STATUS_PREPARED:
    if adapter is not None and execution_binding is not None:
        outcome = adapter.execute(execution_binding)
```

A repository-wide grep for `adapter=` and `execution_binding=` in `tools/` returns
**nothing**. `command_invoke` never passes them, so that path always ends at
`no_authorised_adapter` with `EXIT_DENIED`.

**The privileged transition is not currently wired on this host.** The helpers
`kyri-exec-transition.py` and friends exist in `provisioning/execution/`, the
installed runtime carries `kyri_exec_transition.py`,
`kyri_exec_transition_action.py`, `kyri_exec_verify.py`, `kyri_exec_quota.py`, and
the substrate roots exist and are populated:

```
/data/kyri/capability-runtime          present (execution, quarantine, staging)
/data/kyri/capability-handoff          present, empty
/var/lib/kyri/implementation-authority present, populated (current-generation,
                                       generations, implementations)
```

But `provisioning/execution/sudoers.d/` holds only `kyri-exec.example` and
`kyri-exec-verify.example`, and `/etc/sudoers.d/` contains **zero** Kyri rules. The
privileged transition therefore cannot be invoked via sudo as the platform stands.

These bound urgency. They do **not** change the finding: the enforcement is absent
from the code, not merely unreachable today, and the `authorise-launch` path is
released code that needs only a sudoers rule to complete.

## 4. Operation origin and inventory

Searched for every concept that could represent the action being authorised.

**Where does the literal `execute` originate?** A repository-wide grep for
`'execute'` / `"execute"` as a *value* in `tools/` returns exactly one hit, and it
is unrelated — a keyword list in
`tools/collectors/plugins/manual_attestation/collector.py:38`.

`execute` therefore exists in this platform **only as data**:

| Occurrence | Classification |
|---|---|
| `TrustScope.permitted_operations = ("execute",)` in the operator's Trust grants | **governed operator input** to the Trust plane |
| `admission_scope.permitted_operations` in the frozen `cinst-*.json` bodies | **governed operator input** to admission |
| `CINST-000002.effective_scope.permitted_operations = ['execute']` | **instance effective-scope permission** (intersection of three grants) |
| test fixtures | test data |

**Does it originate only from Trust/admission scope?** Yes. No `CAPDEF`, `CCON`, or
`CPKG` record declares an operation. Verified directly against production:

```
CAPDEF-0001 keys: capability_id, contract_ids, description, effect_class, evidence,
                  kind, name, provenance, schema_version        → effect_class only
CCON-0001   keys: ... effect_class='computational',
                  determinism_class='deterministic'             → no operation
CPKG-0001   keys: artifact_reference, ..., manifest_reference   → no operation,
                  no entrypoint, no command
```

**Is an invoke caller able to request something other than `execute`?** There is
nothing to request. Neither `select`, nor `invoke`, nor `authorise-launch` accepts an
operation argument. `--package-entrypoint` on `authorise-launch` names an entrypoint
inside the staged package; it is an implementation detail of the profile and is
never compared to `permitted_operations`.

**If there is no operation parameter at invoke, what semantic action is being
authorised?** In released terms: *"prepare and, if a mechanism exists, run the
package the selected instance binds, under the contract's effect class."* The only
action-shaped gate on the execution path is `EXECUTABLE_EFFECT_CLASSES` in
`fabric_evidence.py`, which tests the **contract's** `effect_class`, not the
instance's permitted operations.

**If execute is implicit, where is that implicit operation bound to authority?**
It is not. `permitted_operations` is composed at admission and then read by nothing
on the path to execution. That is the gap.

## 5. Effective-scope reader inventory

Complete, repository-wide, runtime source only (tests listed separately).

| Reader | Dimensions structure-validated | Dimensions membership-checked | Dimensions ignored |
|---|---|---|---|
| `fabric/models.py:562,607` (`CapabilityInstance`) | field required and frozen | none | all four |
| `fabric/admission.py:650` `_effective_scope` | all four (non-empty intersection required) | — composes rather than tests | — |
| `fabric/admission.py:1690` | — | **`permitted_capabilities`** (`capability_id in ...`) | — |
| `fabric/admission.py:1700` | — | **`permitted_targets`** (`node in ...`) | — |
| `fabric/admission.py:2225` | carries prior scope forward on lifecycle successor | none | all four |
| `fabric/eligibility.py:589` `_scope_permits` (ELIG-8) | **all four** | **`permitted_data_classifications` only** | capabilities, operations, targets |
| `fabric/eligibility.py:609` `_host_handles` (ELIG-9) | classifications | classifications vs host's declared class | the other three |
| `trust/scope.py:139-142` `evaluate_scope` | — | **all four, including `operation`** | none |
| **`tools/capability/**` (the entire execution layer)** | **none** | **none** | **all four — the field is never read** |

**Does any post-selection / pre-exec component test
`requested_operation in selected_instance.effective_scope.permitted_operations`?**

**No.** Stated directly, as instructed. `tools/capability/` contains zero references
to `effective_scope` or any of its four dimensions.

**The one place operation membership is tested** is `trust/scope.py:140`, inside
`evaluate_scope`. Its reachability was traced:

```
trust/scope.py::evaluate_scope
  ← trust/query.py::evaluate_subject         (only caller)
      ← trust/gateway.py:153                 (only caller)
          ← tools/collectors/*               (only callers: registry, models,
                                              remote/plugin, remote/command_catalog,
                                              validate_plugins)
```

`tools/fabric/trust_adapter.py` imports only `get_current_trust` and
`get_trust_record` from `trust/query.py` — **not** `evaluate_subject`. Neither the
Fabric nor the capability layer can reach `evaluate_scope`. The platform's only
operation check is wired exclusively to the collectors subsystem and is unreachable
from the capability execution path.

## 6. Four-dimension enforcement matrix

Admission-time, selection-time, and invoke-time proof kept strictly separate. A
dimension is **not** marked checked at a later stage merely because an earlier stage
checked it.

| Dimension | Admission (`admit_instance`) | Selection (`select_candidate` / ELIG) | Stage (`prepare_invocation`) | Invoke / launch → execve |
|---|---|---|---|---|
| `capability ∈ permitted_capabilities` | **YES** — `admission.py:1690` refuses if absent | no — ELIG-8 does not test it | no — but `capability_id` **identity chain** equality is checked (`fabric_evidence` CAPDEF/CCON/CINST) | **no** |
| `target ∈ permitted_targets` | **YES** — `admission.py:1700`, node identity | no as a scope test; `_locality_permits` compares `local_node_identity` to the **host record**, not to `permitted_targets` | **no** — no node identity is even supplied to `verify_selected_evidence` | **no** |
| `classification ∈ permitted_data_classifications` | **YES** — via non-empty intersection | **YES** — ELIG-8 | **no** | **no** |
| `operation ∈ permitted_operations` | partial — the intersection must be **non-empty** and Trust-bounded, but no specific operation is ever compared | **no** — no operation exists in the request class | **no** | **no** |

The operation row is the weakest at every stage: even at admission, what is proved
is that *some* operation set survives the intersection of the package grant, the
host grant, and the operator's `admission_scope` — not that a later request for
`execute` is authorised.

## 7. What a persisted CSEL actually authorises

**Answer: A — "this instance is eligible for this request class."** Not B, and the
distinction is stated in source rather than inferred.

`fabric_evidence.py`'s module docstring:

> **These are guards over facts, not eligibility.** Whether an instance *should* be
> selectable is C5's question and was answered before the `CSEL` existed.

`verify_selected_evidence`'s docstring is explicit that support is not permission:

> A supported verdict means the records agree with the caller about what was
> selected and that the binding is still executable as recorded. **It does not mean
> anything ran, and it is not permission to run.**

The persisted `CSEL-000001` carries: `request_class` (five fields), `route_id`,
`route_version`, `selected_instance_id`, `selection_reason`
(`first eligible candidate in declared order`), `considered_candidates`,
`excluded_candidates`, `selected_at`, `local_node_identity`, `provenance`,
`evidence`. **It contains no operation field.**

**May an execution component safely infer an operation from CSEL alone?** No. There
is nothing to infer from — the record does not name one, and its `request_class`
contains no operation dimension. An execution component that assumed `execute`
would be inventing the authority it was supposed to be checking. That inference is
exactly what the platform currently makes implicitly, by never asking.

## 8. Stage semantics

Stage is **materialisation preceded by one authority check**, not an authority
transition of its own.

| Question | Answer |
|---|---|
| Does staging require a CSEL? | **Yes** — `prepare_invocation` calls `verify_selected_evidence` first, and staging runs only `if evidence.supported` |
| Does it validate the selected instance? | Yes — claimed instance must equal `selected_instance_id`; instance must resolve |
| Does it check current eligibility again? | **Partially** — lifecycle `admitted`, not superseded, admission window open at `requested_at`. It does **not** re-run ELIG-1..12 |
| Advertisement / admission freshness? | **admission window: yes. advertisement: NO** — `CADV` is never read by the bridge |
| Does it check `effective_scope`? | **No** |
| Does it name an operation? | **No** |
| Can staging occur for a CSEL whose instance has since expired? | **No** — `_window_open` refuses with `admission-window-not-open` |
| Is CSEL a historical decision or a lease? | **Neither cleanly** — see §10. It is a historical decision that the bridge partially re-validates |

## 9. Invoke semantics — the last refusable point

**The last point where execution can still be refused without side effects is
`verify_selected_evidence`, inside `prepare_invocation`, before
`resolve_and_stage_package`.** Everything after it stages files, allocates a CINV,
and commits a durable record.

At that point:

| Available? | |
|---|---|
| CSEL record | **yes** — read in full |
| CINST record | **yes** — read in full, and `effective_scope` is *inside the record already in hand* |
| CCON record | **yes** |
| CPKG record | **yes** |
| CAPDEF record | **yes** |
| requested operation | **no** — never supplied by any caller |
| `effective_scope` | **present in the data, never read** |
| current-time validity | admission window **yes**; advertisement **no**; Trust **no**; route head **no** |
| node/target identity | **no** — not a parameter of `verify_selected_evidence` |

**This is the concrete enforcement gap.** Two of the three components needed to
prove operation authority are already in hand at the last refusable point — the
instance record carrying `permitted_operations`, and a natural place to refuse. The
third, the requested operation, does not exist anywhere in the platform's request
vocabulary. They are not compared because there is nothing to compare against.

Past the coordinator the question becomes unanswerable: **the entire
`tools/capability/execution/` tree contains no Fabric identity at all** — a
repository-wide grep for `instance_id`, `CINST`, `capability_id`, `CAPDEF`, and
`selection_id` under that directory returns nothing. The launch projection carries
seven fields (`cinv`, `cimp`, `profile_digest`, `handoff_root`,
`profile_schema_version`, `commitment_digest`, `lifecycle_state`) and the handoff
carries two members (`payload`, `profile`). `effective_scope` is not merely
unchecked at the privileged boundary — it is **unavailable** there.

`launch.py`'s own docstring confirms the design intent:

> **It re-runs no governed decision it does not own.** Fabric selection and package
> resolution happened at preparation and are read back from the durable invocation
> record; Trust is not consulted at all.

## 10. Time-of-check / time-of-use

`CSEL-000001` is historical (`evaluated_at = 2026-08-28T20:47:35-05:00`).
`CINST-000002` and `CADV-000003` both expire `2026-08-30T16:19:19-05:00`.

| Re-checked at stage/invoke? | |
|---|---|
| Trusts the historical CSEL forever | **no** — the bridge re-reads and re-checks some facts |
| Current CINST admission window | **YES** — `_window_open(instance, evaluated_at)` |
| Current CINST lifecycle / supersession | **YES** — `instance-not-admitted`, `instance-superseded` |
| Current CADV freshness | **NO** |
| Trust standing | **NO** — explicitly, by design |
| Host/package quarantine, drain, in-service | **NO** |
| Route head | **NO** |
| Selection result recomputed | **NO** — correct; recomputing would be a second selection |

**Can a valid historical CSEL be invoked after its selected instance or
advertisement is no longer eligible?**

- After the **admission window** closes: **no** — refused `admission-window-not-open`.
- After the **advertisement** goes stale but while admission remains open:
  **YES**.

Demonstrated read-only against production data, using `CINST-000001`'s 4h21m36s R17
tail (its `CADV-000002` lapses at `09:24:51`, its admission at `13:46:27`):

```
at 2026-08-29T11:00:00-05:00
  fabric_evidence._window_open   : True      ← the bridge would admit it
  evaluate_eligibility.eligible  : False     ← unmet = ['ELIG-6']
```

So for any instance carrying a non-zero R17 tail, the pre-invoke bridge accepts a
binding the Fabric's own eligibility engine rejects. **This is a second, separate
finding from the operation-scope gap**, and it is classified separately as
instructed.

It is not currently exploitable for `CSEL-000001`: `CINST-000002` has a zero tail by
the G11-Q dependency-bounding ruling, so its advertisement and admission expire
together. The exposure exists for any future instance admitted without that
discipline — which is exactly why G11-S recommended making the bound structural.

The live bridge verdict for the real claim was confirmed read-only:

```
verify_selected_evidence(CSEL-000001, CINST-000002, CPKG-0001, now)
  supported = True, reason = None
  EvidenceVerdict fields: supported, reason, selection_id, instance_id,
    capability_package_id, contract_id, capability_id, effect_class,
    artifact_reference, manifest_reference
  carries scope?     False
  carries operation? False
```

## 11. Negative-path coverage matrix

| # | Case | Status | Citation |
|---|---|---|---|
| 1 | selected instance lacks `execute` in `permitted_operations` | **uncovered** | no test in `tests/test-capability-*.sh` references `permitted_operations`; no such check exists to test |
| 2 | selected instance lacks capability in `permitted_capabilities` | **uncovered at invoke**; covered at admission | `admission.py:1690`; `tests/test-fabric-runtime.sh:7307` (`permitted_capabilities=["observation"]` refused at admission) |
| 3 | selected instance lacks target in `permitted_targets` | **uncovered at invoke**; covered at admission | `admission.py:1700`; `tests/test-fabric-g11-integrity.sh:397-400` (A2) |
| 4 | instance expired after CSEL but before invoke | **covered and fail-closed** | `fabric_evidence._window_open` → `admission-window-not-open`; referenced in 2 test files |
| 5 | advertisement expired after CSEL but before invoke | **uncovered — and the behaviour is wrong** (accepts) | demonstrated in §10; no advertisement read exists in `fabric_evidence.py` |
| 6 | Trust standing changed after CSEL | **uncovered by design** | `fabric_evidence.py` docstring: "Trust is never called"; `launch.py`: "Trust is not consulted at all" |
| 7 | CSEL names an instance inconsistent with the execution request | **covered and fail-closed** | `claimed-instance-not-selected`, `claimed-package-not-bound`; 1 test file each |
| 8 | CSEL is a refusal / no-candidate record | **covered by code, untested** | `REASON_SELECTION_REFUSED` (`selection-recorded-no-instance`) exists at `fabric_evidence.py:172`; **0 test files reference the string** |
| 9 | caller supplies a different operation than admission authorised | **impossible by construction** | no caller can supply any operation — no parameter exists |
| 10 | operation absent entirely | **uncovered** — it is the only possible state, and nothing refuses it | — |

Two further uncovered refusal strings found while building this matrix, reported for
completeness: `instance-superseded` and `record-chain-incoherent` each appear in
**zero** test files despite being live refusal paths in `fabric_evidence.py`.

## 12. Primary conclusion

```
PRE_INVOKE_AUTHORITY = B_GAP
```

An invoke path can reach execution without any component proving that the requested
operation is permitted by the selected instance's governed `effective_scope`.

Reasoning, kept separate from the mitigations:

- No component on the path reads `effective_scope`. Not one — `tools/capability/`
  has zero references to it or its four dimensions (§5).
- No operation value exists anywhere in the request vocabulary (§4).
- Past the coordinator, no Fabric identity crosses the boundary at all, so the check
  is not merely omitted but structurally impossible there (§9).
- The platform's only operation-membership test (`trust/scope.py:140`) is reachable
  solely from `tools/collectors/` and cannot be called from the Fabric or capability
  layers (§5).

Why **B** and not **C**: the safety question asked whether execution can be reached
without the check. That is answered definitively — it can, because the check does
not exist. There *is* a genuine architectural ambiguity underneath (what operation
value should be checked, given no caller supplies one), but that is the shape of the
correction, not an obstacle to naming the gap.

Why **B** and not **A**: no fail-closed operation verification exists to point at.

**Mitigations that bound urgency but do not close the gap**: the released `invoke`
CLI never supplies an adapter and always ends `no_authorised_adapter` (§3.2); the
`authorise-launch` → privileged-transition path requires sudoers rules that are not
installed on this host; and reaching the bridge at all requires a genuine `CSEL`
naming the instance, which is itself governed. The Fabric chain *is* enforced once,
at `verify_selected_evidence` — identity, lifecycle, supersession, admission window,
and effect class. What is missing is the scope dimensions, not the whole chain.

## 13. Smallest RED-first correction proposal — design only, not implemented

The smallest missing element is **a requested operation carried from the invoke
request to the last refusable point, and compared there against the selected
instance's `effective_scope.permitted_operations`.**

| Aspect | Proposal |
|---|---|
| **Which function should own the check** | `tools/capability/fabric_evidence.py::verify_selected_evidence`. It is the last refusable point before side effects, it already holds the instance record containing `effective_scope`, it is the declared authority bridge, and it is C8-read-only so nothing about its safety posture changes. Putting it in `launch.py` is impossible (no Fabric identity there); putting it in selection is the wrong boundary — see §14, Q2. |
| **What operation value it should consume** | A new required keyword argument `operation: str` on `verify_selected_evidence`. No default. A default would authorise by omission, which is what the platform does today. |
| **Where that value comes from** | A new required `--operation` argument on `capability invoke`, forwarded through `prepare_invocation`. It is a governed operator input, exactly as `--selection-id` is a claim the bridge then verifies. |
| **Which governed record provides permission** | `CINST.effective_scope.permitted_operations` — already the intersection of the package Trust grant, the host Trust grant, and the operator's `admission_scope`. No new record, no schema change to any Fabric record. |
| **Exact refusal semantics** | New constant `REASON_OPERATION_NOT_PERMITTED = "operation-not-permitted-by-scope"`, returned by `_refused(...)` like every sibling. Fail-closed on: operation absent, operation not a non-empty string, `effective_scope` absent or malformed, `permitted_operations` absent or empty, or operation not a member. Absence is never permission — the rule `admission.py` already states. Checked **after** the window check and **before** the package/contract chain, so the cheapest governed refusal wins. |
| **Must the CSEL schema/body change?** | **No.** This is the key economy of the proposal. The operation is a property of *this invocation*, not of the selection; a selection remains "this instance is eligible for this request class" (§7). `CSEL-000001` stays valid and needs no re-issue. |
| **Must the invoke/stage body change?** | **Yes, minimally** — one new required CLI argument and one new keyword parameter. The handoff, launch record, profile, and worker are untouched; nothing new crosses the privileged boundary. |
| **Backward compatibility** | Breaking for any caller of `verify_selected_evidence` or `prepare_invocation`, by design. `tools/` has exactly one caller of each (`coordinator.py`, `cli.py`), so the blast radius inside released source is two call sites. Test callers must be updated. Making the parameter optional would preserve compatibility and preserve the gap; it should not be optional. |
| **Tests required (RED first)** | (a) an instance whose `permitted_operations` excludes the requested operation is refused `operation-not-permitted-by-scope`; (b) a member operation is supported; (c) empty `permitted_operations` refuses; (d) absent/malformed `effective_scope` refuses; (e) absent/empty operation refuses; (f) the refusal precedes package and contract resolution, so an unpermitted operation never reaches staging; (g) a signature test that `operation` is required and has no default (the pattern `tests/test-capability-execution-adapter.sh:446` already uses `inspect.signature`); (h) regression pinning that all existing refusals keep their vocabulary and precedence. |

**Separately, and not bundled with the above**: the advertisement staleness finding
(§10) needs its own decision — either `verify_selected_evidence` re-reads the
advertisement, or `admit_instance` enforces `admitted_until <= advertisement
valid_until` structurally, making the tail impossible. G11-S already flagged the
latter as an open question. These are two different corrections and should be two
different checkpoints; combining them would hide which one a test was pinning.

## 14. Architecture questions requiring a reviewer ruling

Named because the correction above assumes answers the reviewer has not given.

1. **Is `operation` a per-invocation property or a per-selection property?** The
   proposal assumes per-invocation, which is why the CSEL schema is untouched. If
   the reviewer decides a selection should authorise a specific operation, the
   request class gains a sixth dimension, `CSEL-000001` becomes historical under an
   older schema, and route matching in `_resolve_route` must decide whether
   operation participates in request-class equality. That is a much larger change.
2. **Should selection-time scope validation be widened?** The proposal says **no**,
   deliberately, per Part K. ELIG-8's classification-only membership is defensible:
   capability and target were enforced at admission against immutable records.
   Widening ELIG-8 would duplicate a settled check at the wrong layer while still
   leaving invoke unguarded. Enforcement belongs where the request is made.
3. **Is admission-time enforcement intentionally sufficient for capability and
   target?** The code behaves as if yes, but says so nowhere. Worth an explicit ADR
   sentence either way, because a future reader will otherwise re-derive this audit.
4. **Should Trust be re-consulted before execution?** Both `fabric_evidence.py` and
   `launch.py` state that it is deliberately not. That is a defensible
   time-of-decision stance, but combined with §10 it means a revoked or quarantined
   subject remains executable through a prepared CINV until the admission window
   closes. The reviewer should confirm this is intended.
5. **Where does `--package-entrypoint` sit?** It is an operator input to
   `authorise-launch` that names what runs inside the staged package, and it is
   compared to nothing in the Fabric. If operation authority is added, the
   relationship between an authorised operation and a chosen entrypoint needs
   stating — otherwise the operation check can be satisfied while a different
   entrypoint runs.

## 15. Route-head hardening — carried forward

`NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING = YES`, unchanged and not touched
here. No route was created or modified. Per Part K, no route-head work was performed
in this checkpoint.

## 16. Production no-mutation proof

Both manifests captured before and after every action and diffed:

```
structural: IDENTICAL
content:    IDENTICAL
CSEL count = 1   capability-selection.seq = 1
/data/kyri/capability-handoff entries: 0
repository worktree: clean
```

Everything in this audit was read-only: record reads through C8 inspection, source
reading, and two read-only calls (`evaluate_eligibility`, `verify_selected_evidence`)
that allocate nothing and write nothing. Two existing suites were run
(`test-capability-fabric.sh`, `test-capability-execution-launch-bridge.sh`); both
passed, and the latter asserts for itself that "no production path changed while
this suite ran".

## 17. Actions not performed

- Nothing staged; nothing invoked; no adapter supplied anywhere.
- No `CSEL-000002`; no route; no `CROUTE-0003`; `CROUTE-0001`/`CROUTE-0002` untouched.
- Nothing withdrawn or retired; no `CINST-000003`; no `CADV-000004`.
- No renewal of `CADV` or `CINST`.
- No patch to route-head enforcement, ELIG-8, scope semantics, replay behaviour, or
  withdrawn-binding routing.
- No mutation of Trust, Artifact authority, or Platform Evidence.
- No Generation-11 reinstall; no sudoers modification; no Root Authority mount.
- No source change, no test added, no implementation commit.
- The persisted `CSEL-000001` was not altered.
- No temporary file was written into any production path.

## 18. Recommended next checkpoint

**A RED-first operation-authority hardening checkpoint**, scoped to §13 alone:

1. Write the eight failing tests first, against current released behaviour, so the
   gap is demonstrated before anything changes.
2. Add `operation` as a required parameter to `verify_selected_evidence`, the
   membership check, and the refusal constant.
3. Thread `--operation` through `command_invoke` and `prepare_invocation`.
4. Register the new suite in `tools/dev/run-validation.sh` and CI.

Before that, the reviewer should rule on §14 Q1 — per-invocation versus
per-selection — because the answer determines whether the CSEL schema is touched,
and therefore whether `CSEL-000001` survives the correction.

The advertisement-staleness finding (§10) and the two uncovered refusal paths
(`instance-superseded`, `record-chain-incoherent`, plus untested
`selection-recorded-no-instance`) should each be scheduled separately rather than
folded into the same change.

## Appendix A — commands executed

```bash
# Starting authority, inventory, both manifests (read-only)
git rev-parse HEAD; git status --porcelain
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# Part A — path mapping
grep -rln 'selection_id|selected_instance_id|capability-selection|CSEL' --include=*.py .
cat tools/capability/fabric_evidence.py tools/capability/coordinator.py
sed -n '285,340p' tools/capability/cli.py            # command_authorise_launch
grep -rn 'prepare_invocation|adapter=|execution_binding=' --include=*.py tools/

# Part B — operation origin
grep -rn "'execute'|\"execute\"" --include=*.py tools/
sed -n '650,700p' tools/fabric/admission.py          # _effective_scope

# Part C — reader inventory
grep -rn 'effective_scope|permitted_operations|permitted_capabilities|
          permitted_targets|permitted_data_classifications' --include=*.py --include=*.sh .
# reachability of trust/scope.py::evaluate_scope traced through query.py and gateway.py

# Part G — what crosses the boundary
grep -rn 'instance_id|CINST|capability_id|CAPDEF|selection_id' \
     --include=*.py tools/capability/execution/     # returns nothing

# Part H — TOCTOU demonstration (read-only)
#   fabric_evidence._window_open vs eligibility.evaluate_eligibility on CINST-000001
#   verify_selected_evidence(CSEL-000001, CINST-000002, CPKG-0001, now)

# Host provisioning state
ls /usr/lib/kyri/python/*.py; ls /etc/sudoers.d/; ls /data/kyri/*

# Suites
bash tests/test-capability-fabric.sh
bash tests/test-capability-execution-launch-bridge.sh
```

## Appendix B — the fabric and the boundary, stated once

```
GOVERNED (Fabric, /var/lib/kyri/fabric)
  CAPDEF-0001 → CCON-0001 → CPKG-0001, CHOST-0001 (node HOST-0001)
  CADV-000001 → CADV-000002 → CADV-000003            head, valid_until 2026-08-30T16:19:19-05:00
  CINST-000001 (adv CADV-000002, R17 tail 4:21:36), CINST-000002 (adv CADV-000003, tail 0)
  CROUTE-0001 → CROUTE-0002                          head, candidates ['CINST-000002']
  CSEL-000001  selected CINST-000002 via CROUTE-0002 v2
  CINST-000002.effective_scope.permitted_operations = ['execute']   ← read by nothing downstream

THE BOUNDARY
  verify_selected_evidence  ← last refusable point; holds effective_scope, never reads it
  ────────────────────────────────────────────────────────────────────────────
  CINV / CIMP / profile / handoff / transition / worker / execve
                            ← carries NO Fabric identity, so the check is impossible here
```
