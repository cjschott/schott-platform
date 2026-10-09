# ENG-0005 §36 closure audit

**Date:** 2026-10-09
**Branch:** `arch/eng-0005-execution-transition`
**Auditor:** Claude (implementation engineer, acting as auditor)
**Scope:** the fifteen acceptance criteria of
[the first-adapter design](../../superpowers/specs/2026-08-11-first-adapter-design.md) §36,
the four mandatory carry-forward findings, the earlier ENG-0005 closure
obligations, and the first-live-use concerns.
**Audit only.** No runtime source, Fabric source, test logic, lifecycle record or
production store was changed.

---

## 0. What the criteria are, and where they come from

§36 of the first-adapter design states fifteen numbered criteria verbatim (quoted
in §2 below). The
[implementation plan](../../superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md)
§8 binds each to a task:

```
1–3 → T10/T11 · 4 → T12 · 5 → T8/T20 · 6 → T2/T3 · 7 → T14 ·
8–9 → T13 · 10 → T6 · 11 → T6 · 12 → T5 · 13 → T21 · 14–15 → T22
```

That mapping, not my judgement, decides which evidence is the right evidence.

### Two plan-named suites do not exist

Auditing the plan's own file list first, before any criterion:

| plan-named suite | task | status |
|---|---|---|
| `tests/test-capability-execution-integration.sh` | T20 | **ABSENT** |
| `tests/test-capability-execution-failure-injection.sh` | T21 | **ABSENT** |

Every other suite the plan names is present. These two absences bear directly on
criteria 5 and 13, and both are addressed in place rather than noted and skipped.
In each case the substance was found elsewhere; what is missing is the file the
plan promised, which is an evidence-organisation finding recorded as **F5** in §4.

### Evidence tiers used

In the brief's order of preference: production records and the real filesystem
first; then the installed runtime; then real-container E2E; then clean-clone test
evidence; then unit/injected. Where a criterion rests on a lower tier than it
could, that is stated.

### The authority this audit was taken against

| | |
|---|---|
| Fabric | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |
| chain | `CADV-000008` · `CINST-000007` · `CROUTE-0007` · `CSEL-000005` |
| current authority | `supported=True reason=None eligibility_reasons=[]` |
| production execution | `CINV-000003` → `CRES-000002` `outcome_class: completed` |

Fabric and runtime were re-measured after every executable group in this audit
and were **unchanged**.

---

## 1. The installed privileged boundary, measured

Several criteria depend on what is actually installed, so it is established once
here rather than asserted repeatedly.

All eight helpers declared in `tools/capability/execution/helpers.py` are
installed, and every installed digest equals its declaration:

| path | mode | owner | role |
|---|---|---|---|
| `/usr/libexec/kyri-exec-transition` | 0555 | root:root | privileged launch entrypoint |
| `/usr/libexec/kyri-exec-worker.py` | 0444 | root:root | worker the transition execs |
| `/usr/libexec/kyri-exec-reconcile` | 0555 | root:root | privileged reconciliation entrypoint |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | 0444 | root:root | unprivileged reconciliation half |
| `/usr/lib/kyri/python/kyri_exec_transition.py` | 0444 | root:root | policy module |
| `/usr/lib/kyri/python/kyri_exec_transition_action.py` | 0444 | root:root | **the credential drop** |
| `/usr/lib/kyri/python/kyri_exec_reconcile.py` | 0444 | root:root | reconciliation implementation |
| `/usr/lib/kyri/python/kyri_exec_quota.py` | 0444 | root:root | quota module |

**8 declared, 0 mismatched, 0 absent.** None is setuid; `getcap` reports no file
capabilities on either executable — which is what the design requires, since
gate G3 records that introducing a setuid bit or file capability is a re-ruling.

**A correction to my own first reading.** I initially probed
`/usr/lib/kyri/kyri-capability-transition` and `/etc/sudoers.d/kyri-capability`,
found both absent, and was on the verge of recording the privileged helper as
uninstalled. Those paths were my invention; the design names
`/usr/libexec/kyri-exec-*` and `/etc/sudoers.d/kyri-exec`. The helper is
installed. I record the error because an audit that guesses paths can manufacture
a blocker as easily as it can miss one.

**One real discrepancy does remain.** The reviewed example
`provisioning/execution/sudoers.d/kyri-exec.example` describes the production
grant as `/etc/sudoers.d/kyri-exec`. What is installed is
`/etc/sudoers.d/kyri-exec-launch` and `/etc/sudoers.d/kyri-exec-reconcile`
(both root:root 0440); there is no `/etc/sudoers.d/kyri-exec`, and no
`kyri-exec-verify` drop-in. Their contents are mode 0440 root:root and so are not
readable at the operator's privilege level, which means **the installed grant's
text was not verified by this audit**. See **F6** in §4.

---

## 2. The fifteen criteria

### Criterion 1 — "`CINV` grammar rejected at both sudoers and helper layers, proven independently."

- **Requirement.** Two independent validators of `^CINV-[0-9]{6}$`, so that
  neither is the only one.
- **Implementation.** The sudoers layer constrains the sole argument by regex
  (`Cmnd_Alias KYRI_EXEC_TRANSITION = sha256:… /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$`).
  The helper revalidates independently; the reviewed example states the reason in
  terms this audit endorses — "a policy layer that is the only validator is one
  syntax error away from being no validator."
- **Tests.** `test-capability-execution-helper-policy.sh` (35 PASS): *every
  malformed CINV shape is refused*; *record identity and digest fields are
  grammar-checked*. `test-capability-execution-transition-action.sh` (48 PASS)
  runs entirely unprivileged and proves the policy layer independently.
- **Production.** `CINV-000001`…`CINV-000003` all conform; the transitions
  namespace holds only well-formed identities.
- **Classification: PASS_WITH_ACCEPTED_FINDING.** The helper layer is proven
  independently and directly. The *sudoers* layer is proven only from the
  reviewed repository example, because the installed drop-in is 0440 root:root.
  The finding is F6; it does not block, because the helper layer alone refuses
  every malformed shape, which is the property that matters if the policy layer
  were absent entirely.
- **Residual risk.** The installed regex could differ from the reviewed example
  without this audit detecting it. Bounded: a weaker installed regex cannot widen
  authority past the helper's own check.
- **Blocks G7?** No.

### Criterion 2 — "Helper refuses when the authorised transition context cannot be established."

- **Requirement.** No partial transition: if the context cannot be established,
  nothing executes.
- **Implementation.** `kyri_exec_transition_action.py`; the entrypoint
  "establishes the output quota, drops credentials, sets `no_new_privs`, and"
  execs the worker.
- **Tests.** `test-capability-execution-transition-action.sh`: *the transition
  refuses unless it holds root*; *a credential verification that still shows
  privilege prevents the exec*; *a refused transfer prevents the drop and the
  exec*; *the transfer happens while privilege is still held*.
- **Production.** `CINV-000003` reached `launch_authorized` then `concluded`; no
  invocation is stranded between states.
- **Classification: PASS.** Refusal is proven at each precondition, and the
  ordering — verify, then transfer, then drop, then exec — is asserted directly.
- **Residual risk.** None identified.
- **Blocks G7?** No.

### Criterion 3 — "Root demonstrably never execs Podman."

- **Requirement.** The container runtime is reached only after the credential
  drop.
- **Implementation.** `kyri-exec-worker.py` loads `kyri_exec_podman` **after**
  the drop; its header states the worker runs with credentials already dropped to
  `kyri-capability` with `no_new_privs` set and "no privileged step left here to
  perform". The privileged layer contains no reference to Podman.
- **Tests.** `test-capability-execution-transition-action.sh`: *the privileged
  layer never mentions Podman or a container runtime*. `test-capability-execution-helper-policy.sh`
  carries the complementary assertions.
- **Production.** The output leaf `/data/kyri/capability-handoff/CINV-000003/out`
  is owned `kyri-capability:kyri-capability` — the process that wrote it was not
  root and not the operator.
- **Classification: PASS.** Proven by construction (root's module graph excludes
  the runtime) and corroborated by production ownership.
- **Residual risk.** None identified.
- **Blocks G7?** No.

### Criterion 4 — "Worker demonstrably cannot write any authority root."

- **Requirement.** The unprivileged worker holds runtime authority and no
  governance authority.
- **Implementation.** `kyri-exec-worker.py` takes "three fixed-grammar tokens"
  and derives everything else; the split is stated as "the authority split the
  whole transition exists to create".
- **Tests.** `test-capability-runtime.sh` (1089 PASS): *the capability store is
  not a FabricStore*; *it shares no record kind with the Fabric*; *it shares no
  identifier prefix with the Fabric*; **writing a capability record leaves the
  Fabric store byte-unchanged**.
- **Production / real E2E.** The invoke E2E reports *fabric authority unchanged*
  with a full per-file manifest, across a success path and a seven-case failure
  matrix. Across this entire audit, Fabric and Trust were byte-unchanged.
- **Classification: PASS.** The strongest available tier: a real execution wrote
  capability records and left the authority stores byte-identical.
- **Residual risk.** None identified.
- **Blocks G7?** No.

### Criterion 5 — "Profile fields verified against observed Podman state, field by field."

- **Requirement.** The observed container must match the profile per field, and a
  mismatch must fail closed.
- **Implementation.** `verify_observed(profile, observed)` at
  `tools/capability/execution/profile.py:637`.
- **Tests.** `test-capability-execution-profile.sh` (26 PASS) and
  `test-capability-execution-runtime-observation.sh` (13 PASS), which prove the
  observation is *derived* rather than taken from a Podman field: *observe derives
  sockets rather than reading a Podman field*; *an extra socket bind the runtime
  reports is refused by T8*; *an expected profile saying none cannot make a socket
  disappear*; *a symlinked source is refused rather than followed to safety*.
- **Real E2E.** `test-capability-invoke-execution-e2e.sh` drives real containers
  and its failure matrix is exactly the field-by-field proof: `extra-mount`,
  `socket-mount` and `wrong-user-mapping` each yield `adapter-error`, `CINV` spent,
  `containers=1`, `orphan=NO`. A divergence in a single profile dimension fails the
  invocation.
- **Production.** The published profile for `CINV-000003` hashes to
  `f6696e0dac6d70fea602897e70adb746ab9f82ddaf94527f674d677d7ace05ee`, exactly the
  `profile_digest` pinned in its launch authorisation, and carries the
  security-critical fields explicitly: `cap_drop_all: true`,
  `dropped_capabilities: [ALL]`, `no_new_privileges: true`, `privileged: false`,
  `read_only_rootfs: true`, `network: none`, `host_network: false`,
  `host_pid: false`, `pids_limit: 64`, `memory_bytes: 268435456`,
  `cpu_quota_us: 50000`, `execution_uid/gid: 65532`, tmpfs `nodev,noexec,nosuid`.
- **Classification: PASS_WITH_ACCEPTED_FINDING.** The property is proven at the
  real-E2E tier against live containers. What cannot be re-measured is the
  **production** container's observed state field by field: that container was
  disposed of, as the design requires, so the observation is not re-derivable
  after the fact. The finding is F5 — T20's named integration suite never existed,
  and the coverage lives in the invoke E2E instead.
- **Residual risk.** Production field-by-field observation rests on the
  disposed-container record rather than a retained observation. Accepted: retaining
  it would conflict with disposal.
- **Blocks G7?** No.

### Criterion 6 — "Payload canonicalisation rejects duplicates at depth, non-integer numbers, U+0000, unpaired surrogates."

- **Requirement.** Exactly those four rejection classes.
- **Tests.** `test-capability-execution-canonical-json.sh` (33 PASS): *refuses
  duplicate keys at the top level*; *at nesting depth 3*; *inside an array
  element*; *duplicate detection precedes canonicalisation*; *refuses fractions
  and exponents*; *refuses NaN and infinities in every spelling*.
  `test-capability-execution-payload.sh` (27 PASS) covers the contract bound.
- **Production.** `CINV-000003`'s `payload_digest`
  `sha256:591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3`
  is the canonical digest of the reviewed payload, and the Stage-0 ceremony
  independently reproduces it from the committed payload.
- **Classification: PASS.** All four classes are asserted, and the ordering
  property — duplicates detected *before* canonicalisation — is asserted too,
  which is the part a reimplementation would get wrong.
- **Residual risk.** None identified.
- **Blocks G7?** No.

### Criterion 7 — "Output collector rejects symlink, FIFO, socket, device, traversal, and over-bound trees, including trees over-bound by depth or entry count alone."

- **Tests.** `test-capability-execution-collector.sh` (35 PASS): *a valid result
  beside a symlink fails the invocation*; *beside a FIFO or a socket*; *a device
  node beside a valid result*. `test-capability-execution-cleanup.sh` (24 PASS)
  carries the bound cases: *a subtree deeper than 32 is incomplete and stops
  deleting*; *more than 8192 entries is incomplete and stops deleting*.
- **Note on scope.** The criterion says "over-bound by depth or entry count
  **alone**" — i.e. a tree that is otherwise valid. Both are asserted as distinct
  cases, not as a combined one.
- **Production.** The collected result for `CINV-000003` is
  `sha256:fd2d58e99bae82f32ce320a3d3ac2a35b6e679b87432b2aedd9de1efa92cbad7`; the
  E2E reports *result content `{'ok': True, 'value': 42}`*, *host output owner
  preserved (1000, 1000)*, *output mode not widened 448*.
- **Classification: PASS.**
- **Residual risk.** None identified.
- **Blocks G7?** No.

### Criterion 8 — "Timeout classification is permanent across a grace-period exit."

- **Tests.** `test-capability-execution-terminal.sh` (24 PASS): *the accepted
  timeout and grace are 30 and 2 seconds*; *the timeout fires at the threshold,
  not before*; **a timeout classification is permanent and cannot revert**;
  *timeout outranks a nonzero exit and a contradiction alike*; *no kill is issued
  when the container stops within the grace*; *the grace is bounded to two
  seconds*.
- **Real E2E.** The invoke failure matrix includes `timeout → reason=timeout,
  class=timeout, containers=1, orphan=NO` against a real container.
- **Classification: PASS.** Both halves are proven: permanence, and that a
  within-grace stop does not become a kill.
- **Blocks G7?** No.

### Criterion 9 — "`Created` with exit 0 classifies as launch failure."

- **Tests.** `test-capability-execution-terminal.sh`: *Created with exit 0 is a
  launch failure, never success*; *Created with a nonzero exit is the same launch
  failure*.
- **Classification: PASS.** The second assertion matters as much as the first —
  it proves the classification is driven by the lifecycle state, not by the exit
  code.
- **Blocks G7?** No.

### Criterion 10 — "Capacity honours 2 and refuses the third."

- **Tests.** `test-capability-execution-capacity.sh` (31 PASS): *a valid
  reservation commits reserved and consumes one slot*; *a second independent
  reservation takes the second slot*; **the third reservation is refused as
  `execution_capacity_exhausted`**; *a refused reservation leaves no queue and no
  state behind*; *no age-based expiry*; *there is no rollback from reserved to
  unused*. `test-capability-execution-capacity-race.sh` (5 PASS) proves it under
  real concurrency: *eight concurrent reservations never exceed the two-slot
  ceiling*; *sixteen concurrent reservations still commit exactly two*.
- **Production.** `test-capability-execution-abandonment.sh` reproduces the real
  ceiling: *two `launch_authorized` invocations hold both slots and a third is
  refused* — "reproduced: all 2 execution slots are held".
- **Classification: PASS.** Concurrency-proven, not merely sequential.
- **Blocks G7?** No.

### Criterion 11 — "Lock order is enforced and inversion is impossible by construction."

- **Tests.** `test-capability-execution-capacity.sh`: **lock order is global
  capacity then per-CINV, and inversion raises**. `capacity-race`: *conflicting
  transitions from one predecessor cannot both commit*; *release racing a
  reservation never overcounts or double-counts a slot*.
- **Classification: PASS_WITH_ACCEPTED_FINDING.** Order is enforced and
  inversion raises — proven. "Impossible **by construction**" is the stronger
  claim the criterion makes, and a raising runtime check is enforcement, not
  structural impossibility. The distinction is recorded rather than glossed.
- **Residual risk.** A future caller could acquire in the wrong order and meet a
  raise at runtime rather than a compile-time impossibility. Bounded: the raise
  fails closed, and the race suite shows no interleaving defeats it.
- **Blocks G7?** No.

### Criterion 12 — "Every authority mutation has a CMUT intent and outcome."

- **Production evidence, directly.** All **12** mutation records in
  `/data/kyri/capability-runtime/execution/mutations/` carry **both** an `intent`
  and an `outcome` member — checked individually, none partial. The counter reads
  `000000000012`, matching the record count.
- **Tests.** `test-capability-execution-mutation.sh` (38 PASS), including real
  crash injection: *crash after intent, before installation: unknown, target
  absent*; *crash after installation, before outcome: unknown, target proven
  present*; *a completed mutation is not reported as unknown*; *recovery never
  replays an installation*; *allocated gaps stay burned across an interruption*.
- **Classification: PASS.** Production records satisfy it exhaustively, and the
  interrupted case is proven to report *unknown* rather than guess.
- **Blocks G7?** No.

### Criterion 13 — "Crash injection at each §24 boundary yields the specified classification."

§24 names nine boundaries. Coverage, boundary by boundary:

| §24 boundary | specified outcome | evidence |
|---|---|---|
| before `reserved` | nothing consumed | *a refused reservation leaves no queue and no state behind*; *there is no rollback from reserved to unused* (capacity) |
| after `reserved`, before `launch_authorized` | `transition_failed_before_execution` | *policy refusal before any transition classifies as `transition_failed_before_execution`* (helper-policy) |
| after `launch_authorized`, no container ID | candidate discovery, else `execution_state_lost` | recovery-discovery, 13 assertions incl. *an unproven supervised invocation is INSPECTED, not skipped*; *blocks readiness until disposal is proven* |
| after create, before `container_verified` | fingerprint decides; mismatch fails closed | profile (26) + container-identity (14); E2E `wrong-image`/`extra-mount`/`socket-mount`/`wrong-user-mapping` → `adapter-error` |
| after `start_authorized` | §17 start reconciliation | supervision: *start is granted once, after the profile, and names the container*; *an unproven disposal yields no outcome at all* |
| during execution | Podman state authoritative | reconciliation (6 assertions); supervised E2E *disposal proven*, *container absent afterwards* |
| during collection | `quarantine_collection_incomplete` | quarantine (21 PASS) |
| during cleanup | `execution_cleanup_incomplete`, slot held | cleanup: *a missing handoff root is incomplete, never quiet success*; *a directory substituted between the look and the open is incomplete* |
| CMUT intent without outcome | outcome unknown; no replay | mutation, by **actual crash injection** (above) |

- **Classification: PASS_WITH_ACCEPTED_FINDING.** Every one of the nine
  boundaries yields its specified classification, and three are reached by
  genuine injection — crash-after-intent, crash-after-installation, and a
  directory substituted between the look and the open (a real TOCTOU race). The
  finding is twofold: T21's named suite
  `tests/test-capability-execution-failure-injection.sh` **does not exist**, and
  for the remaining boundaries the classification is proven by *constructing the
  boundary condition* rather than by crashing a live process mid-operation. The
  outcomes are the specified ones either way.
- **Residual risk.** A crash whose partial state no constructed fixture
  anticipates. Bounded by the mutation suite's unknown-rather-than-guess
  behaviour and by `supervision.py`'s invariant that an unproven disposal returns
  no terminal outcome at all.
- **Blocks G7?** No.

### Criterion 14 — "No adapter path exists that reaches Fabric, Trust, or Health."

- **Tests.** `test-capability-runtime.sh`: *the capability store is not a
  FabricStore*; *it shares no record kind with the Fabric*; *it shares no
  identifier prefix with the Fabric*; *the Fabric still has exactly eight record
  kinds*; **writing a capability record leaves the Fabric store byte-unchanged**.
- **Real E2E / production.** *fabric authority unchanged* with a per-file
  manifest across the success path and all seven failure cases. Trust was
  byte-unchanged through every run in this audit.
- **Classification: PASS.**
- **Blocks G7?** No.

### Criterion 15 — "Package-wide backstop proves no new execution authority beyond this adapter."

- **Tests.** `test-capability-runtime.sh`: *a hostile artefact reaches only the
  adapter boundary (`no_authorised_adapter`)*. `test-static.sh` holds the
  package-wide negative assertions (*no premature implementation:
  `tools/enrollment`*, `tools/clustering`, `tools/scheduler`) and **197 shell
  conformance assertions**. `test-no-production-escape.sh` (4 PASS, `ok`-style):
  *every released CLI verb is classified: 9 verbs*; *none of the 150 test suites
  dispatches a governed mutator without naming its target*; *the 2026-09-24 shape
  — dispatching abandon at `CINV-000001` — is absent*.
- **Installed-runtime.** No setuid bit and no file capability on either
  privileged executable; the authorised helper surface is exactly 8 declared
  objects, all digest-matched.
- **Classification: PASS.** The backstop is package-wide and includes a standing
  regression for a real past incident.
- **Blocks G7?** No.

---

## 3. Closure table

| # | Criterion | Class | Strongest tier |
|---|---|---|---|
| 1 | CINV grammar, both layers | PASS_WITH_ACCEPTED_FINDING | installed runtime (helper); repo example (sudoers) |
| 2 | Helper refuses without context | PASS | unit, unprivileged |
| 3 | Root never execs Podman | PASS | production ownership |
| 4 | Worker cannot write authority | PASS | real E2E + production |
| 5 | Profile vs observed, field by field | PASS_WITH_ACCEPTED_FINDING | real E2E |
| 6 | Payload canonicalisation | PASS | unit + production digest |
| 7 | Collector rejections | PASS | unit + production result |
| 8 | Timeout permanent across grace | PASS | real E2E |
| 9 | `Created` + exit 0 → launch failure | PASS | unit |
| 10 | Capacity 2, refuses third | PASS | concurrency + production ceiling |
| 11 | Lock order, inversion impossible | PASS_WITH_ACCEPTED_FINDING | concurrency |
| 12 | Every mutation has intent + outcome | PASS | **production records (12/12)** |
| 13 | Crash injection at each §24 boundary | PASS_WITH_ACCEPTED_FINDING | injection (3 of 9) + constructed (6 of 9) |
| 14 | No adapter path to Fabric/Trust/Health | PASS | real E2E + production |
| 15 | Package-wide backstop | PASS | package-wide static + installed runtime |

**Total 15 — PASS 11 · PASS_WITH_ACCEPTED_FINDING 4 · BLOCKED 0 · NOT_APPLICABLE 0.**

---

## 4. The carry-forward findings

### F1 — `create-route` accepts temporally impossible `recorded_at` values

- **Evidence.** Six instants probed against the released engine (G11-BC-AQ, AR):
  `would_accept: true` for a route recorded a second before its candidate's
  admission, a day before, exactly at expiry, after both windows close, and dated
  tomorrow.
- **Architecture defect or acceptable limitation?** **Defect in depth of
  enforcement, not in authority.** The engine's contract is to judge at the
  instant a request names; it does not cross-check one record's instant against
  another's window. Nothing is widened by it — the record is exactly as truthful
  as its author made it — but a reviewer reading "the engine accepted it" learns
  less than they think.
- **Mitigated by.** **Ceremony only.** `g11-bc-ar-croute-0007-freeze.txt` gate 5
  refuses all six cases, exercised individually; `test-fabric-renewal-chain-rehearsal.sh`
  holds the ordering for the suite.
- **Could it permit unsafe production mutation without a ceremony?** **Yes, in
  principle** — a route written outside the freeze ceremony could carry an
  impossible instant and be accepted. It could not grant authority the records do
  not already carry, and the downstream selection would still have to resolve.
- **Closure-blocking?** **No.** Every production write in ENG-0005 went through a
  freeze artifact carrying the gate.
- **Follow-up owner.** A Fabric-engine increment (ENG-0006 candidate), with an
  ADR deciding whether the engine should enforce cross-record temporal ordering or
  whether that remains ceremony authority by design.

### F2 — `select` may return `would_accept=true` while `selected_instance_id` is null

- **Evidence.** Eight instant pairs (G11-BC-AS): the engine never refuses on
  temporal grounds; outside the admission window it resolves to `null` while still
  reporting `would_accept: true`. `recorded_at` has no effect on resolution at
  all — only `evaluated_at` moves it.
- **Architecture defect or acceptable limitation?** **The more serious of the
  four.** An accepted selection that selects nothing is a durable governed record
  asserting a decision that resolves to no instance. The engine is internally
  consistent — it records refusals as selections by design, so "nothing was
  selected" is a legitimate recorded outcome — but `would_accept` is a misleading
  name for the answer a caller gets.
- **Mitigated by.** **Ceremony only.** `g11-bc-as-csel-000005-freeze.txt` gate 6
  asserts `selected_instance_id == CINST-000007` and refuses null explicitly,
  ahead of `would_accept`.
- **Could it permit unsafe production mutation without a ceremony?** **Yes** — and
  this one has a demonstrated consequence: had `CROUTE-0007` not been renewed, a
  selection through the old head would have been *accepted* while resolving to
  null. That was measured, not hypothesised.
- **Closure-blocking?** **No** — the written `CSEL-000005` resolves to
  `CINST-000007`, verified by content, and current authority is `supported=True`.
  It is the finding most deserving of an engine change.
- **Follow-up owner.** Same Fabric-engine increment as F1, ranked first within it.

### F3 — `request_digest` does not cover `request_id`

- **Evidence.** Proven for `create-route` (AQ) and `select` (AS): changing only
  `request_id` leaves the digest identical; `actor`, `recorded_at` and
  `local_node_identity` each change it.
- **Architecture defect or acceptable limitation?** **Acceptable limitation,
  correctly scoped.** The digest identifies the *decision content*, which is the
  right identity for replay determinism. `request_id` is recorded in
  `evidence.request_id` and is covered by the body SHA-256.
- **Mitigated by.** **Both.** The runtime records the id durably; the ceremonies
  pin the body SHA *and* the digest and read `request_id` out of the body
  (AR gate 4, AS gate 4). A standing test in the chain rehearsal asserts the
  coverage boundary, including that `actor` *does* change the digest so the test
  cannot pass by the digest being inert.
- **Could it permit unsafe production mutation without a ceremony?** **No.** It
  changes what a digest identifies, not what any authority permits.
- **Closure-blocking?** **No.**
- **Follow-up owner.** Documentation increment: state the digest's coverage in the
  Fabric design so no future gate pins the digest alone.

### F4 — matrix/freeze suites previously contained kind-specific assumptions

- **Evidence.** Three freeze-suite checks demanded advertisement/admission prose
  of a route and would have forced the route artifact to claim authority over the
  package, host, architecture and operation (AR); the matrix's authority defaults
  named the pre-renewal chain and two of its messages asserted expiry as a
  standing fact (AT). **All were mine.**
- **Architecture defect or acceptable limitation?** **Neither — a test-quality
  defect**, and the most self-implicating item here. The pattern is checks
  satisfied by *prose* rather than by *structure*: they passed for two checkpoints
  because every artifact in the table happened to be an advertisement or an
  admission, and they failed only when a different record kind arrived.
- **Mitigated by.** Fixed: the checks are kind-aware, each kind naming its own
  dimensions and stating where the others live; the superseded-banner regex now
  matches by shape rather than enumerating checkpoint letters.
- **Could it permit unsafe production mutation without a ceremony?** **No, but it
  is the finding most likely to let one through unnoticed** — a prose-satisfied
  check reports agreement with its own template.
- **Closure-blocking?** **No.** All four instances are repaired and the suites
  pass at 90 and 42.
- **Follow-up owner.** A test-quality pass over the freeze and matrix suites for
  remaining prose-satisfied checks, rather than discovering them one record kind
  at a time. **This audit did not perform that sweep** and does not claim the four
  found are all there are.

### F5 — two plan-named suites do not exist *(new, raised by this audit)*

`tests/test-capability-execution-integration.sh` (T20) and
`tests/test-capability-execution-failure-injection.sh` (T21) are named by the
plan, including as T20's `**GREEN:**` gate command, and are absent. Their
substance is covered — criterion 5 by the invoke E2E's mismatch matrix,
criterion 13 across eight suites — but the plan's own acceptance command cannot be
run as written.

- **Closure-blocking?** **No.** The properties are proven at an equal or higher
  tier than a single integration suite would give.
- **Follow-up owner.** A plan-reconciliation increment: either create the named
  suites or amend §8's mapping to name the suites that actually carry the
  evidence. Leaving a plan that names a non-existent GREEN gate is a trap for the
  next auditor.

### F6 — the installed sudoers grants were not read by this audit *(new)*

The reviewed example names `/etc/sudoers.d/kyri-exec`; what is installed is
`kyri-exec-launch` and `kyri-exec-reconcile`, both root:root 0440 and therefore
unreadable at the operator's privilege level. The *installed* grant text —
command path, runas, NOPASSWD scope, digest, and the `^CINV-[0-9]{6}$` regex —
is consequently unverified here.

- **Closure-blocking?** **No**, on two grounds: the helper revalidates the grammar
  independently (criterion 1), and the helper binary is root-owned and
  non-writable so a grant over it cannot be subverted by file replacement.
- **Follow-up owner.** An operator-run read-back ceremony: `sudo cat` both
  drop-ins, `visudo -c`, and `sha256sum /usr/libexec/kyri-exec-transition`
  compared to the installed `Cmnd_Alias` digest. **This is the one item I would
  schedule before G7 rather than after**, because it is cheap and it is the only
  §36 criterion resting on a repository example rather than an installed fact.

---

## 5. The other closure obligations

| Obligation | Evidence | Class |
|---|---|---|
| Governed execution lifecycle | `reserved → launch_authorized → concluded` in production for `CINV-000003`; lifecycle (31 PASS) | PASS |
| Capacity accounting | capacity 31 + race 5; production ceiling reproduced | PASS |
| ABANDONED closure | abandonment 26 PASS: *`launch_authorized` cannot reach released, so no slot can be given back*; `CADM-000001`/`000004` in production | PASS |
| CONCLUDED closure | conclusion 33 PASS: *concluded is terminal, holds no slot*; *`launch_authorized` is the only state that reaches concluded*; `CADM-000003` in production | PASS |
| Provenance correction ADR-0016/0018 | provenance-correction 22 PASS: *only provenance claims are correctable, and no lifecycle claim is*; `CADM-000002`/`5`/`6`/`7` | PASS |
| Generation 23 legacy compatibility | legacy-compatibility 13 PASS: *the synthesised legacy shape matches production's real `CADM-000002`*; *a legacy record resumes, and is not called different authority* | PASS |
| No-production-escape guard | 4 `ok`: 9 verbs classified, 150 suites checked, the 2026-09-24 incident shape absent as a standing regression | PASS |
| Supervised execution E2E | real containers: *started proven*, *disposal proven*, *container absent afterwards*, *the coordinator holds no output tree* | PASS |
| Privileged transition coverage | transition-action 48 PASS; 8 installed helpers digest-matched | PASS |
| Real kernel vs injected coverage | see §6 | PASS_WITH_ACCEPTED_FINDING |
| Fabric authority renewal | the four-record renewal verified by content at AO/AQ/AS/AT, each with mutation accounting PASS | PASS |
| Stale evidence / rehearsal handling | spent-mode branching across stage 0–3; five **named** accepted baselines, exact-match, no wildcard | PASS |
| Immutable record semantics | every predecessor byte-identical after supersession; *residue is neither reused nor rewritten* | PASS |
| Append-only mutation accounting | four reconstructions, each exactly two files moved | PASS |
| Transaction / install generation coherence | generation-succession passes; 23 installer suites | PASS |
| Recovery behaviour | recovery-discovery 13 `ok`: *readiness returns only after the invocation was actually checked*; *the safety gate wrote nothing* | PASS |
| Cleanup behaviour | cleanup 24 PASS: *incomplete, never quiet success*, bounded at depth 32 / 8192 entries | PASS |
| Handoff retention | `handoff_retained: true` in `CADM-000003`, corroborated — the subtree is still present | PASS |
| Stranded lifecycle handling | *an unproven supervised invocation is INSPECTED, not skipped*; *blocks readiness until disposal is proven* | PASS |
| Trust/Fabric/runtime separation | three stores byte-unchanged through every run; no shared kind or prefix | PASS |
| Execution identity | identity-authority: *each reader derives its own deployment's identity*; *an identity number that is not a usable non-root id is refused*; production `execution_uid/gid: 65532` | PASS |
| Helper authority | 8 declared helpers, digests matched, no setuid, no file capabilities; helper-coherence 9 PASS | PASS |
| Quota ordering | quota 17 PASS: *quota authority is one ioctl*; *the quota covers the output leaf only*; the entrypoint establishes quota **before** the drop | PASS |
| Descriptor closure | *a descriptor is returned, not a path*; *the descriptor is bound to the file that was checked*; *still yields the bytes that were validated* | PASS |
| `no_new_privs` | `PR_SET_NO_NEW_PRIVS = 38` via ctypes, set **after** the drop; production profile `no_new_privileges: true` | PASS |
| Container disposal proof | *disposal proven*, *container absent afterwards*, *worker reaped*; `orphan=NO` across all seven failure cases | PASS |
| Result recording | `CRES-000002` `completed` with digest; *CRES written for the failed execution*; *a replayed identity is refused* | PASS |
| Slot release semantics | `slot_released: true` in `CADM-000003`; *conclude is absent from the destruction-authority mapping*; *release racing a reservation never overcounts* | PASS |

---

## 6. First-live-use review

Stage 3 production execution is `CINV-000003` → `CRES-000002`, concluded by
`CADM-000003` with **`derivation: reconstructed`**. ADR-0017 licenses that
explicitly: a terminal `CRES` from the supervised path is itself proof the
container was created, ran, concluded and was disposed of, because
`supervision.py` raises rather than returning an outcome it cannot prove. The
reconstruction is labelled in the record, so no reader is left guessing which
kind of claim it is.

| Concern | Evidence | Verdict |
|---|---|---|
| **Real credential drop** | `/data/kyri/capability-handoff/CINV-000003/out` is owned `kyri-capability:kyri-capability` 0700 inside a `cschott`-owned tree. `kyri-capability` is a real `nologin` account, uid 999, distinct from the operator (uid 1000). The directory was written by a process holding neither the operator's nor root's identity. Source: `kyri_exec_transition_action.py`, digest-matched as installed. | **PROVEN in production, on the real kernel** |
| **Saved-ID crossing** | The action layer carries real, effective **and saved** ids because "checking only the effective ones would miss a saved-uid that permits regaining privilege", and refuses the exec if a post-drop verification still shows privilege: *a credential verification that still shows privilege prevents the exec*. Order asserted: `setgroups` → `setgid` → `setuid`. | **PROVEN** — mechanism installed and asserted; production corroborates the drop took effect |
| **Root-only ownership transfer** | `out` is owned by a *different* user inside a tree the operator owns; only root can chown across users, so the transfer happened under privilege, as designed. *the transfer happens while privilege is still held*; *a refused transfer prevents the drop and the exec*. | **PROVEN in production** |
| **sudo / helper execution** | `/usr/libexec/kyri-exec-transition` installed root:root 0555, digest matching its declaration; `/etc/sudoers.d/kyri-exec-launch` installed root:root 0440; `CINV-000003` reached `launch_authorized` and produced a terminal `CRES`. | **PROVEN that it executed**; the grant's *text* is unread — **F6** |
| **Real quota application** | `/data` is XFS mounted `prjquota`, so project quotas are active. The module is one `FS_IOC_FSSETXATTR` ioctl; the design pins project `1_000_000 + CINV` (so `1000003`) at 32 MiB / 512 inodes on `out/`; the entrypoint establishes it before the drop; 17 assertions cover the surface. **But** the quota suite states *nothing was installed and no quota was established* — it does not apply a real quota — and the applied project id on `out/` is **not readable at this privilege level**: `lsattr -dp` → Permission denied, `xfs_quota -x -c report` → `XFS_GETQUOTA: Operation not permitted`, `repquota` absent. Sibling entries show project 0, consistent with "the output leaf only". | **NOT PROVEN** — mechanism and filesystem support proven, applied value unverified |

**`FIRST_LIVE_USE_REVIEW = PASS`**, with real quota application classified
honestly as unproven rather than inferred from the mechanism being installed.
Four of the five are proven by production facts on the real kernel; the fifth
needs one root-level read.

**Why this does not block.** A quota that failed to apply would widen a
*resource* bound, not an authority bound: the output leaf is still
`kyri-capability`-owned, still unreadable by the coordinator, still bounded by
collector depth and entry-count limits, and `/data` has 490 GB free against a
32 MiB intent. The unverified value is a containment depth, not a containment
boundary.

---

## 7. G7 readiness

**`G7_READY = YES`.**

All fifteen §36 criteria are classified, none BLOCKED. Eleven PASS, four
PASS_WITH_ACCEPTED_FINDING, every finding with a stated reason and a named
follow-up owner. The O3 obligation is closed against live production. Every other
recorded closure obligation has concrete evidence, and the strongest tier
available was used in each case — production records for criterion 12, real
kernel ownership for the credential drop, real containers for the profile and
disposal properties.

**Two things a reviewer should weigh before entering G7.**

**First, one cheap item I would do before G7 rather than after: F6.** It is the
only §36 criterion resting on a repository example rather than an installed fact,
and it costs one `sudo cat`, one `visudo -c` and one `sha256sum`. I did not do it
because the audit brief forbids production changes and I could not read the file
without escalating; I am not treating "I could not read it" as "it is correct".

**Second, O3's closure is wall-clock-bounded.** The live matrix passes 22/0
because authority is live until `2026-10-13T06:25:00-05:00` — about 95 hours from
this audit. After that it masks again with nothing regressed. If G7 is entered
after that instant, the matrix evidence must be re-taken against a renewed chain,
and the renewal is now a proved, repeatable four-step ceremony.

**What I am not claiming.** That the four F4 instances are the only
prose-satisfied checks in the suites — I fixed the ones a new record kind
exposed and did not sweep for the rest. That is F4's follow-up, and it is the
finding most likely to hide the next one.

---

## 8. Related records

- [§36 criteria](../../superpowers/specs/2026-08-11-first-adapter-design.md)
- [Task mapping, §8](../../superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md)
- [ADR-0017 post-execution lifecycle conclusion](../../decisions/ADR-0017-post-execution-lifecycle-conclusion.md)
- [G11-BC-AT, O3 closed](../reports/eng-0005/2026-10-09-g11-bc-at-renewal-verified-o3-closed.md)
- [G11-BC-AK, the obligations this audit discharges](../reports/eng-0005/2026-10-01-g11-bc-ak-post-correction-acceptance.md)
