# ENG-0005 G11-X — Per-Invocation Operation Authority and Effective-Scope Enforcement

- Checkpoint: ENG-0005 G11-X
- Date: 2026-08-28 (local date at report creation)
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `48e21381bb3bee548c6c9d0986986cbdda5dce94`
- Host: `schai`
- Result: `ACCEPTED`

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `48e21381bb3bee548c6c9d0986986cbdda5dce94` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-W report present | yes |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Governed chain | `CADV-000003 → CINST-000002 → CROUTE-0002 → CSEL-000001`, unchanged |
| Generation 11 runtime | 57 `.py` files, digest `80f9dee2…07b5f` |
| Root Authority | unmounted |
| Kyri sudoers rules installed | 0 |

Production manifests captured before any work: fabric structural 30 entries,
content 21 files, plus a `/data/kyri` manifest.

## 2. The reviewer's per-invocation ruling, implemented

`operation` is per-invocation authority. Selection answers *which admitted binding
serves this governed request class*; invocation answers *what action is being
requested through that binding now*. The invoke boundary names the operation
explicitly, and nothing infers it.

Implemented exactly as ruled:

- `--operation` is **required** on `capability invoke`. Absent, the CLI refuses
  with exit 2: `the following arguments are required: --operation`.
- `verify_selected_evidence` takes `operation` as a **keyword-only argument with no
  default**. A default would authorise by omission.
- Nothing infers the operation from the `CSEL`, the contract's `effect_class`, the
  package entrypoint, the adapter, or the implementation profile.
- Unusable text (empty, whitespace-only, untrimmed, or non-string) is refused as
  `operation-not-supplied`, not repaired. A value that had to be corrected to match
  is not the value that was supplied.

## 3. Why the CSEL schema is unchanged

No change was made to `CapabilitySelection`, the selection body schema, the CSEL
request class, route equality, `CROUTE` records, or `CSEL-000001` itself.

The reason is the ruling's own logic. A selection records a decision about a
*request class*; an operation is a property of *one invocation through* that
binding. Putting the operation in the CSEL would mean a new selection for every
action, and would drag the operation into `_resolve_route`'s request-class equality,
where it would begin partitioning routes. `CSEL-000001` therefore remains valid
historical governance evidence with no migration, and no `CSEL-000002` was needed.

Confirmed against production after the change: `CSEL-000001` is byte-identical, and
the fabric manifests are unchanged (§14).

## 4. Initial RED evidence

The suite was written and run **before** any implementation change. Captured output:

```
PART 1 — the interface carries an operation, explicitly
FAIL: verify_selected_evidence takes an operation
FAIL: prepare_invocation takes an operation
FAIL: the invocation binding digest takes an operation
FAIL: the durable invocation record carries the operation

PART 2 — the permitted request is supported
TypeError: verify_selected_evidence() got an unexpected keyword argument 'operation'
```

The gap G11-W described is reproduced mechanically: the interface to carry an
operation did not exist, so no scope comparison could be made.

New suite: `tests/test-capability-invocation-operation-authority.sh`, 6 parts,
55 assertions.

## 5. The invoke operation interface

The smallest explicit path from operator to the enforcement point:

```
capability invoke --operation <action>
   → cli.py::command_invoke        (args.operation)
   → coordinator.py::prepare_invocation(operation=...)
   → fabric_evidence.py::verify_selected_evidence(operation=...)
```

| Surface | Change |
|---|---|
| `cli.py` | `--operation` added, `required=True`, no default |
| `coordinator.py` | `operation` added to `prepare_invocation`, forwarded to the bridge and to `bind` |
| `fabric_evidence.py` | `operation` added as a required keyword-only parameter |
| `invocation_identity.py` | `operation` joins `BINDING_FIELDS` and the binding digest |
| `records.py` | `operation` joins the closed `INVOCATION_FIELDS` |
| `evidence.py` | the durable `CINV` body records the operation |

Six runtime files. No new record kind, no new store, no schema version bump.

## 6. Four-dimension enforcement

All four dimensions are enforced at the invocation boundary, in
`verify_selected_evidence`, against the selected instance's `effective_scope`:

```python
capability_claimed  in scope[SCOPE_CAPABILITIES]
requested           in scope[SCOPE_OPERATIONS]
classification      in scope[SCOPE_CLASSIFICATIONS]
node                in scope[SCOPE_TARGETS]
```

**Where each value comes from** — governed authority wherever one exists, so the
caller can name only the one thing it must:

| Dimension | Value | Source |
|---|---|---|
| capability | `CINST.capability_id` | the instance record already read |
| **operation** | `--operation` | **the caller — the only new input** |
| classification | `CSEL.request_class.data_classification` | the governed request class the selection recorded |
| target | `CHOST.node_identity_reference` | the host the instance binds, resolved through the same C8 read-only surface |

The classification is deliberately *not* caller-supplied: a caller able to name it
could name a narrower classification than the request it is actually making.

**Placement.** After the admission-window check and **before** package and contract
resolution, so the cheapest governed refusal wins and a request outside scope never
reaches a staging decision. Proved by two assertions in Part 5 of the suite: with
the package removed, and separately with the contract removed, an unpermitted
operation still refuses as `operation-not-permitted-by-scope` rather than as an
absent record.

**Why this is not duplicated work.** Admission composed the scope by intersecting
the package grant, the host grant, and the operator's admission scope, and refused
an empty result. That established what *may* be asked for, against no particular
request. This establishes that what *is* being asked for is one of those things.

**Target identity, not host identity.** `permitted_targets` holds node identities.
The bridge resolves `CHOST-0001` only to read `node_identity_reference` and compares
`HOST-0001`. A test pins this directly: a scope whose `permitted_targets` names
`CHOST-0001` instead of `HOST-0001` is **refused**. No new authority input was
required — the host record was already reachable through `inspect_records`.

## 7. Refusal vocabulary

One reason per dimension, following the module's existing hyphenated convention.
Collapsing them would tell an operator that something was out of scope without
saying which thing, and the four are cleared in four different places.

| Constant | String |
|---|---|
| `REASON_OPERATION_ABSENT` | `operation-not-supplied` |
| `REASON_OPERATION` | `operation-not-permitted-by-scope` |
| `REASON_CAPABILITY_SCOPE` | `capability-not-permitted-by-scope` |
| `REASON_CLASSIFICATION_SCOPE` | `classification-not-permitted-by-scope` |
| `REASON_TARGET_SCOPE` | `target-not-permitted-by-scope` |
| `REASON_SCOPE` | `invalid-effective-scope` |
| `REASON_HOST_ABSENT` | `host-not-found` |

No existing reason was overloaded. All seven are pinned by tests. Reason strings
name the dimension only — never the requested value, the permitted set, or any
record content.

An incomplete scope is `invalid-effective-scope`, never treated as permissive: a
dimension the record leaves out bounds nothing and therefore permits nothing. That
is the same rule admission already applies.

## 8. Operation bound to the invocation evidence

An invocation digest already existed — `invocation_identity.bind()` over the payload
and the claim. The operation is caller-controlled authority, so it now participates:

```
BINDING_FIELDS = ("invocation_id", "selection_id", "instance_id",
                  "capability_package_id", "operation", "actor")
```

Pinned by test: `bind(operation="execute", ...) != bind(operation="delete", ...)`
with everything else identical, and stable for a fixed operation. An operator
therefore cannot have `operation=execute` checked and then present a different
action under the same binding digest — the digest would disagree.

The operation is **also** written into the durable `CINV` record (`INVOCATION_FIELDS`
gains `operation`), so the digest can be recomputed and audited from the record
alone. A digest covering a value the record does not carry would not be verifiable
after the fact.

Nothing was added to CSEL evidence.

## 9. Positive test

With the exact production-shaped chain — `CSEL-000001` selecting `CINST-000002`,
`operation="execute"`, scope permitting `CAPDEF-0001` / `execute` / `internal` /
`HOST-0001`:

```
PASS: the exact selected chain with a permitted operation is supported (None)
PASS: a supported verdict names no refusal
PASS: the verdict carries the selected instance
PASS: verification wrote nothing to the fabric
```

Verification proceeds to the next existing boundary and no further. No adapter was
executed, no `execve` was reached, and no staging was performed.

## 10. Negative matrix

Every row run, each dimension independently fail-closed. Each also asserts the
refusal wrote nothing.

| Requested | Allowed scope | Result |
|---|---|---|
| `CAPDEF-0001` | contains | **continue** |
| capability outside scope | excludes | refuse `capability-not-permitted-by-scope` |
| `execute` | contains | **continue** |
| `delete` | excludes | refuse `operation-not-permitted-by-scope` |
| `internal` | contains | **continue** |
| classification outside scope | excludes | refuse `classification-not-permitted-by-scope` |
| `HOST-0001` | contains | **continue** |
| target outside scope | excludes | refuse `target-not-permitted-by-scope` |
| `CHOST-0001` named as target | node identity absent | refuse `target-not-permitted-by-scope` |

Also proved:

| Case | Result |
|---|---|
| operation absent (`None`) | `operation-not-supplied` |
| operation empty / whitespace-only | `operation-not-supplied` |
| operation not a string | `operation-not-supplied` |
| `permitted_operations` empty | `operation-not-permitted-by-scope` |
| `effective_scope` absent | `invalid-effective-scope` |
| `effective_scope` not a mapping | `invalid-effective-scope` |
| a scope dimension missing entirely | `invalid-effective-scope` |
| a scope dimension holding non-text | `invalid-effective-scope` |
| host record absent | `host-not-found` |
| host declares no node identity | `record-chain-incoherent` |
| selection carries no request class | `record-chain-incoherent` |

Pre-existing refusals keep their exact vocabulary and precedence — a CSEL that
selected nothing (`selection-recorded-no-instance`), a claimed instance the
selection did not choose, a non-admitted instance, a superseded instance, a closed
admission window, a package the instance does not bind, and a non-executable effect
class. **`instance-superseded` and `selection-recorded-no-instance` had zero test
coverage before this checkpoint** (G11-W §11); both are now pinned.

## 11. Refusal precedes staging and CINV allocation

Structurally guaranteed, not merely observed. In `prepare_invocation`, staging runs
only inside `if evidence.supported:`, and the `CINV` is allocated afterwards by
`record_invocation`. A refusal returns an unsupported verdict before either.

Within the bridge, the scope checks sit before package and contract resolution, so
an out-of-scope request does not even resolve the artefacts a staging decision would
need. Each of the 16 negative cases asserts the fabric fixture is byte-identical
after the refusal — no write, no allocation, no lifecycle transition, no adapter
call, no handoff.

## 12. Regression results

| Suite | Result |
|---|---|
| `test-capability-invocation-operation-authority.sh` (new) | PASS (run twice) |
| `test-capability-fabric.sh` | PASS (run twice) |
| `test-capability-runtime.sh` | PASS |
| `test-capability-execution-launch-bridge.sh` | PASS |
| `test-capability-execution-launch-cli.sh` | PASS |
| `test-capability-execution-adapter.sh` | PASS |
| `test-capability-execution-helper-policy.sh` | PASS |
| `test-capability-execution-g5-preflight.sh` | PASS |
| `test-fabric-preflight.sh` | PASS |
| `test-fabric-route-preflight.sh` | PASS |
| `test-fabric-advertisement-preflight.sh` | PASS |
| `test-fabric-instance-admission-integrity.sh` | PASS |
| `test-fabric-g11-integrity.sh` | PASS |
| `test-platform-model.sh` | PASS |
| `test-fabric-runtime-install-closure.sh` | PASS |

### 12.1 Fixtures the hardening necessarily changed

Four existing suites carried fixtures that predate the boundary and had to be
brought up to the shape released governance actually writes. Each change adds
authority the fixture was missing; none weakens an assertion.

- **`test-capability-runtime.sh`** — the shared `_chain` fixture gained a
  `capability-host` record declaring `HOST-0001`, an `effective_scope` on the
  instance, and a `request_class` on the selection. Its `_verify` helper passes
  `operation="execute"`. The `_evidence` stub, the `BINDING` fixture, three
  hand-built `bind` calls, the hand-built `_cinv` body, and the CLI argument map
  each gained the operation. 29 `_verify` call sites now exercise the new boundary.
- **`test-capability-execution-launch-bridge.sh`** and
  **`…-launch-cli.sh`** — their local `Evidence` stubs and `bind` calls gained the
  operation.

### 12.2 A structural limit in the G5 preflight, surfaced and repaired

The Generation-5 preflight declares a pinned delta between the checkout's runtime
half and the installed runtime, one row per file:
`source|operation|installed_baseline_digest|next_generation_digest`. A row can
express exactly one hop, and a host must be at either the baseline (pending) or the
next digest (applied).

This checkpoint puts the checkout **two hops** ahead for `cli.py` and `evidence.py`:
the test fixture is a generation-6 host, the real host is generation 11, and the
checkout is now beyond both. No single-baseline row can describe both, so the
preflight refused with `neither pending nor applied` on one host or the other
whichever digest was chosen.

The repair is minimal and widens only the installed side: a row may name several
comma-separated baselines, and `generation_declares` accepts the installed digest if
it is any of them.

```bash
local baselines
baselines=",$(field "${row}" 2),"
[[ "${baselines}" == *",${installed},"* ]] || return 1
```

**The checkout side stays absolute** — the checkout must still carry exactly the
declared bytes, so nothing unreviewed becomes admissible by naming another baseline.
Six rows were declared or updated for this generation: `fabric_evidence.py`,
`invocation_identity.py`, `records.py`, `coordinator.py`, `cli.py`, `evidence.py`.

A method note: my first attempt used a `while read` loop over `tr ','` output, which
silently dropped the final unterminated line and broke every pre-existing
single-baseline row. The substring match above has no such edge.

## 13. Full validation

| Mode | Result |
|---|---|
| `run-validation.sh --quick` | **passed, 75/75 steps** |
| `run-validation.sh` (full) | **passed, 98/98 steps** |
| `pre-commit run --all-files` | passed (bash -n, shellcheck 0.9.0, whitespace, no tracked bytecode, static assertions) |
| `shellcheck -S warning` on changed shell | clean |

Both totals were re-measured from real runs rather than incremented: quick moved
74 → 75 and full 97 → 98, because the new suite is in the unconditional section and
runs in both modes. It is registered in `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`.

## 14. Production no-mutation proof

```
fabric structural manifest : IDENTICAL
fabric content manifest    : IDENTICAL
/data/kyri manifest        : IDENTICAL
installed runtime digest   : 80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b (unchanged)
CSEL count = 1   handoff entries = 0   Kyri sudoers rules = 0
```

Nothing was staged, invoked, or launched. No Fabric record was created or altered.
Trust, Artifact authority, and Platform Evidence are untouched. Generation 11 was
not reinstalled and the Root Authority was not mounted. The new suite carries its
own production-path guard and reports `no production path changed while this suite
ran`.

### 14.1 ⚠ The correction is in the repository, not yet in the installed runtime

The installed Generation-11 runtime at `/usr/lib/kyri/python` is **deliberately
unchanged** — reinstalling is outside this checkpoint's boundary. So the enforcement
added here is **not yet active on this host**. `test-fabric-runtime-install-closure.sh`
continues to pass precisely because it exercises the installed bytes.

A future generation must install this change before any production invoke. Until it
does, the installed bridge is the one G11-W audited.

## 15. Unresolved for G11-Y — advertisement freshness and current eligibility

`INVOKE_CURRENT_ELIGIBILITY_HARDENING_REQUIRED_BEFORE_PRODUCTION_INVOKE = YES`.

Not folded in here, as instructed. G11-W proved that `verify_selected_evidence`
re-checks the admission window but never reads the advertisement, so a binding with
a non-zero R17 tail stays invocable after Fabric eligibility has failed ELIG-6. The
demonstration stands unchanged: at `2026-08-29T11:00:00-05:00`, `_window_open`
accepts `CINST-000001` while `evaluate_eligibility` reports `unmet=['ELIG-6']`.

`CINST-000002`'s tail is zero (`admitted_until == CADV-000003.valid_until`), so the
current chain is not exposed to that particular tail. Trust standing, host and
package quarantine, drain, and route head are likewise not re-checked at the
boundary. G11-Y should decide which of those belong at invoke time and which are
settled by the immutable records.

## 16. Route-head hardening — carried forward

`NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING = YES`. `create_route` was not
touched. No route was created, modified, or superseded.

## 17. Actions not performed

- Nothing staged, invoked, or launched; no adapter enabled; no `execve`.
- No `CSEL-000002`; no change to the selection schema, request class, route
  equality, or `CSEL-000001`.
- No route successor; no `CROUTE-0003`; `create_route` unchanged.
- Nothing withdrawn or retired; no `CINST-000003`; no `CADV-000004`.
- ELIG-8 **not** changed — enforcement was placed at the invocation boundary, which
  is where the request is made, rather than duplicated into selection.
- Advertisement/TOCTOU freshness not addressed (§15).
- Replay semantics and withdrawn-binding routing untouched.
- No sudoers installed; Root Authority not mounted; Generation 11 not reinstalled.
- No mutation of Trust, Artifact authority, or Platform Evidence.
- No ENG-0006 work; no TrustGateway cutover.

## 18. Readiness for G11-Y

Ready. The per-invocation authority contract is explicit, required, fail-closed, and
pinned by tests in both directions.

G11-Y should address invoke-time current eligibility: whether the bridge re-reads
the advertisement, or whether `admit_instance` enforces
`admitted_until <= advertisement.valid_until` structurally so the tail cannot exist
— G11-S raised the latter as an open question and it remains the cheaper fix. The
two are alternatives, and choosing one is a reviewer decision.

One further item for whoever schedules the next generation: §14.1. The enforcement
is committed but not installed, and a production invoke against the current
installed runtime would still reach staging without a scope check.

## Appendix A — commands executed

```bash
# Preflight and manifests (read-only)
git rev-parse HEAD; git status --porcelain
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )

# RED first
bash tests/test-capability-invocation-operation-authority.sh     # failed, as designed

# Implementation: six runtime files, then the fixtures the change invalidated
# Declared delta for the G5 preflight, both baselines per affected row

# Verification
bash tests/test-capability-invocation-operation-authority.sh     # twice
bash tests/test-capability-runtime.sh
bash tests/test-capability-execution-launch-bridge.sh
bash tests/test-capability-execution-launch-cli.sh
bash tests/test-capability-execution-g5-preflight.sh
bash tests/test-fabric-{preflight,route-preflight,advertisement-preflight}.sh
bash tests/test-fabric-{instance-admission-integrity,g11-integrity}.sh
bash tests/test-platform-model.sh
shellcheck -S warning provisioning/execution/g5-preflight.sh \
  tests/test-capability-invocation-operation-authority.sh tools/dev/run-validation.sh
pre-commit run --all-files
bash tools/dev/run-validation.sh --quick        # 75/75
bash tools/dev/run-validation.sh                # 98/98

# Fail-closed check at the interface
python3 -m tools.capability.cli invoke ... (no --operation)   # exit 2
```

## Appendix B — the boundary, after this checkpoint

```
CSEL-000001  selected CINST-000002 via CROUTE-0002        (unchanged, no operation)
      │
      │  capability invoke --operation execute            ← named, never inferred
      ▼
verify_selected_evidence(operation=...)                   ← the authority boundary
      ├─ selection resolves, names this instance
      ├─ instance admitted, not superseded, window open
      ├─ effective_scope well-formed                      invalid-effective-scope
      ├─ capability      ∈ permitted_capabilities         capability-not-permitted-by-scope
      ├─ operation       ∈ permitted_operations           operation-not-permitted-by-scope
      ├─ classification  ∈ permitted_data_classifications classification-not-permitted-by-scope
      ├─ node identity   ∈ permitted_targets              target-not-permitted-by-scope
      ├─ package / contract chain coherent
      └─ effect class executable
      ▼
resolve_and_stage_package → bind(operation) → CINV(operation) → launch → execve
                                    ▲
                       the operation is in the binding digest and the
                       durable record, so what was authorised cannot be
                       changed without changing its evidence
```
