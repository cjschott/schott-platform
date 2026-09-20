# G11-BC-T — Stage 0 verified; CINV-000003 Stage 1 prepared

ENG-0005. 2026-09-20. Branch `arch/eng-0005-execution-transition`.

CINV-000003 Stage 0 was verified independently of the reviewer's report: the
work area, its security properties, and both payload digests.

The **Stage 1** ceremony was then prepared, gated six times, and rehearsed
whole — including the real `capability invoke` write against a copy of the
production runtime store, so the identity, sequence and record fields the
operator's run will produce are known before it is authorised.

**Stage 1 is the first irreversible step.** Nothing was performed against
production.

---

## 1. Starting source authority

| | |
| --- | --- |
| HEAD at start | `2a1324b90aa8e6b3ddcfafa79c9320722d7fd8e5` |
| required source authority | `2a1324b90aa8e6b3ddcfafa79c9320722d7fd8e5` ✔ |
| branch | `arch/eng-0005-execution-transition` ✔ |
| origin | contains HEAD at the same commit ✔ |
| working tree | clean; nothing staged, nothing untracked ✔ |
| G11-BC-S report | present ✔ |
| Stage 0 ceremony artifact | present ✔ |

## 2. Live governed chain and runtime

```
fabric aggregate    a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5   ✔
runtime aggregate   159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc   ✔
capability-invocation.seq  2      capability-result.seq  1                            ✔
CINV-000003                absent        CRES for CINV-000003  absent                 ✔
```

| record | observed |
| --- | --- |
| CADV-000007 | `observed_at 2026-09-19T06:00:00-05:00`, `valid_until 2026-09-23T06:00:00-05:00` |
| CINST-000006 | `admitted`, rests on CADV-000007, `admitted_until 2026-09-23T06:00:00-05:00` |
| CROUTE-0006 | `route_version 6`, `candidate_instances [CINST-000006]` |
| CSEL-000004 | through CROUTE-0006 v6, selects CINST-000006, considered `[CINST-000006]`, excluded `[]` |

Fabric validation: `status reported`, `findings []`, counts CADV 7 / CINST 6 /
CROUTE 6 / CSEL 4. Trust: `valid true`, `problems []`.

Runtime, Platform Evidence and Artifact authority match the aggregates recorded
in G11-BC-S (`70011c72…`, `62c87585…`, `ef4297c6…`). Root Authority unmounted.

## 3. Stage 0's durable output, verified

```
/data/kyri/work/g11bcn                    uid 1000  cschott:cschott  mode 0700
/data/kyri/work/g11bcn/third-invoke.json  uid 1000  cschott:cschott  mode 0600
                                          regular file, 1 hard link, 300 bytes
raw sha256       d01faccc67b83c60051348422861c121211a4079f7748572bad0a4882575a569   ✔
canonical bytes  271                                                               ✔
canonical digest 591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3   ✔
operation        verify-execution-boundary      arguments.count 1                   ✔
arguments.label  g11bcn-third-controlled-production-invoke                          ✔
note binds       CADV-000007 / CINST-000006 / CROUTE-0006 / CSEL-000004             ✔
```

The canonical values were recomputed with the released canonicalizer, the same
function Stage 1 uses to fill `payload_digest`. The placed payload is
**byte-identical** to `provisioning/execution/g11-bc-n-cinv-000003-payload.json`.
The work area was not rewritten.

These are exactly the properties `open_trusted_regular_file` will check on the
**descriptor** at invoke time: a regular file, owned by the expected uid, not
group- or other-writable, exactly one hard link, under a root owned by that uid
and not group- or world-writable.

---

## 4. The released Stage 1 contract, reconstructed

Read from `tools/capability/cli.py` (`command_invoke`),
`tools/capability/coordinator.py` (`prepare_invocation`),
`tools/capability/evidence.py` (`record_invocation`),
`tools/capability/package_resolution.py` (`resolve_and_stage_package`) and the
accepted CINV-000001 / CINV-000002 Stage 1 reports. **It matches the contract
G11-BC-S reported.** Nothing was modified to make it true.

### Command and arguments

`python3 -m tools.capability.cli invoke` with, all required: `--store-root`,
`--expected-uid/--expected-gid`, `--fabric-root`,
`--fabric-expected-uid/--fabric-expected-gid`, `--approved-artifact-root`,
`--trusted-source-uid`, `--staging-root`, `--coordinator-uid`,
`--approved-payload-root`, `--payload-source-uid`, `--payload-file`,
`--invocation-id`, `--selection-id`, `--instance-id`, `--package-id`,
`--operation`, `--trust-store-root`, `--actor`, `--request-id`,
`--requested-at`.

### Exit code and verdict

`command_invoke` ends with an unconditional `return EXIT_DENIED` under the
comment *"Every outcome reachable here is a governed negative"*, and
`EXIT_DENIED = 1`. It supplies neither an adapter nor an execution binding, so
`_bound_adapter_identity(None, None)` is `None`, nothing can execute, and
`prepare_invocation` returns `prepared` with `REASON_NO_ADAPTER`.

```
process exit   1                        <- SUCCESS. The JSON is the verdict.
status         prepared
reason         no_authorised_adapter
```

### Allocation rules, and the one that matters most

`record_invocation` enters `store.invocation_critical_section(identity)`, looks
for a prior record, and then **allocates the CINV before it decides whether the
evidence supports the invocation**. On the refusal branch it allocates a CRES
as well and writes a refusal result.

> **The identity is spent even when the invocation is refused.** There is no
> path that reaches the invoke and allocates nothing. A refused Stage 1 would
> consume CINV-000003 *and* CRES-000002.

That is why the gates are worth their cost here in a way they were not at Stage
0, where the whole ceremony could be abandoned for free.

A replayed `invocation_id` resolves to the existing CINV and returns `consumed`
or `conflict` — a different, non-idempotent outcome. Stage 1 must not be re-run.

### Bindings

`verify_selected_evidence` is given the operator's *claim* of selection and
instance and decides whether the claim is true — a coordinator that read the
instance out of the selection and then "verified" it would be checking its own
arithmetic. `payload_digest` is sha256 over the canonical form. The binding
digest covers payload, invocation id, selection, instance, package, operation
and actor.

### Staging

A tree already published under the same commitment is **re-inspected in full
and adopted**, not rebuilt — asked before the source is read. The commitment
`tree-sha256-6f2282c5…` is already staged from CINV-000001/000002, so
`staging/` does not change.

### What Stage 1 may do, measured

Rehearsed by running the real write against a copy of the production runtime
store and diffing the file list:

```
create  capability-invocations/CINV-000003.yaml      one file, mode 0600
change  sequences/capability-invocation.seq  2 -> 3
```

Nothing else. No CRES, no execution state, no lock or journal file surviving
the critical section, no staging change, no Fabric write.

### Recovery after Stage 1

An invocation with a durable record and no terminal result is the honest
interrupted state, and it is what `capability recover` enumerates. It must not
be closed by hand: doing so destroys the evidence the enumeration acts on. If
the ceremony refuses *after* the invoke has run, the instruction is stop and
report — not re-run.

### Successful stop after Stage 1

CINV-000003 written with the reviewed fields; `capability-invocation.seq` = 3;
`capability-result.seq` still 1; no CRES; no execution state; one staged
commitment; Fabric byte-identical.

---

## 5. Stage 1 preflight and rehearsal

### Preflight, against a scratch runtime with production Fabric read-only

```
would_accept                     true
outcome                          preflight
predicted_invocation_record_id   CINV-000003
selection_id                     CSEL-000004
instance_id                      CINST-000006
capability_package_id            CPKG-0001
operation                        execute
payload_digest                   sha256:591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
current_eligibility              true        eligibility_reasons []
scope_permits_operation          true
package_tree_sha256              sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
```

The payload was read from the **real accepted Stage 0 work area**, so the
trusted-source requirements were exercised against the file the operator will
present.

### The real write, against a copy of the runtime store

```
process rc              1
status                  prepared
reason                  no_authorised_adapter
invocation_record_id    CINV-000003
result_record_id        null
payload_digest          sha256:591d4b0d…7d3c59b3
binding_digest          sha256:6d5a8d92…2dc86289
artifact_digest         sha256:6f2282c5…20e6c9a8e
capability-invocation.seq   2 -> 3        capability-result.seq   1 (unchanged)
files added                 exactly one: capability-invocations/CINV-000003.yaml
```

The payload was not executed, no CRES was allocated, no Stage 2 authorisation
was created, no execution state appeared, and production was byte-identical
before and after.

### One thing that cannot be pinned, and is not

**The persisted record's SHA-256 is not predictable and is deliberately not
pinned.** `requested_at` carries the operator's clock, so the bytes differ on
every run by construction. The ceremony pins the eighteen *fields* instead —
including `adapter_identity: null`, which is what makes an unresolved
invocation distinguishable later: it says no mechanism was ever authorised, so
an absent result means nothing was attempted rather than that something ran
unaccounted for.

Inventing a record SHA would have been a pin the released contract cannot
define.

---

## 6. The Stage 1 ceremony

`provisioning/execution/g11-bc-n-cinv-000003-stage-1-ceremony.txt`. Prepared,
not performed.

### Two blocks, because one of them needs a different account

**BLOCK A — observation.** Read-only. It lists containers and images as
`kyri-capability` through `sudo runuser`, refuses a pre-existing
`kyri-CINV-000003` or any `kyri-CINV-*` container, requires the execution image
`5cee2b53…` and the `localhost/kyri-capability-execution:g5` tag, and writes a
witness recording what it concluded.

It runs `cd /tmp` first. `runuser` inherits the caller's working directory and
`kyri-capability` cannot traverse `/opt/schott-platform` — which is exactly why
the Stage 0 observation failed the first time it was run. That correction is
built in rather than left to be rediscovered.

**BLOCK B — the gates and the one irreversible command.** It contains no
`sudo`: a privilege prompt between the gates and the allocation is the last
thing this ceremony should have. It gates on the witness instead, requiring it
to exist, be owned by uid 1000, be **no older than 900 seconds**, and record
both conclusions by name. A stale observation is not an observation.

### The six gates, all before the invoke

| gate | what it establishes |
| --- | --- |
| **0** | the observation was made, recently, and concluded what BLOCK B needs |
| **1** | CADV-000007 fresh, CINST-000006 admission open and `admitted_until <= valid_until`, CROUTE-0006 routing to exactly CINST-000006, CSEL-000004 binding that route and instance — five live records on five argv channels |
| **2** | current eligibility through the released evaluator at the current clock |
| **3** | Fabric and runtime aggregates exact, both sequences exact, CINV-000003 absent, Trust valid |
| **4** | the Stage 0 work area: uid, modes, one hard link, raw digest, canonical digest and semantics |
| **5** | the released preflight agrees: `would_accept`, predicted CINV-000003, the payload digest, and the resolved selection, instance, package and operation |

All use the corrected G11-BC-P/Q/R/S patterns: each input on its own argv
channel, stdin carrying only program text, every gate a plain command under
`if !` so its status is its own, an instant with no timezone offset refused
rather than guessed.

### The invoke, and why `set +e` is load-bearing

```bash
set +e
python3 -m tools.capability.cli invoke … > "${INVOKE_FILE}"
INVOKE_RC=$?
set -e
```

Under `set -Eeuo pipefail` an expected `rc=1` would kill the shell **after the
record was written and before anything verified it** — the worst possible
moment to lose control of the ceremony. The block disables errexit for exactly
one command and restores it immediately.

`rc` is then required to be **exactly 1**. The exit code is not the verdict,
but it is not ignored either: `rc=0` from this command would mean the released
contract had changed underneath the ceremony, and the block refuses rather than
proceeding on an assumption.

### After the invoke

Every check is on what was written, and every refusal says **STOP AND REPORT,
do not re-run**. The verdict must be the exact released success — status,
reason, allocated identity, invocation id, all three digests, the staged path,
and `result_record_id: null`, which is what distinguishes a *prepared*
invocation from a *refused* one that allocated a result. Then the record's
fields and mode, both sequences, the absence of a CRES, the single staged
commitment, the absence of execution state, and Fabric unchanged.

The block ends by telling the operator to stop: Stage 2 is a separate
authorisation.

---

## 7. Rehearsal and the failure matrix

The whole of BLOCK B runs to completion against a fixture copied from the
production Fabric, runtime and accepted work area, reaching the real invoke and
producing the released success. 281 assertions.

BLOCK A is not run — it needs `sudo` and a test may not assume that. The suite
writes the witness BLOCK A would write, and separately proves BLOCK B refuses
an **absent**, **stale**, **future-dated** or **wrong** witness, which is the
whole of what BLOCK B relies on it for.

**Structural checks on the block itself:** BLOCK B contains no `sudo`; BLOCK A
does `cd /tmp`; BLOCK B runs exactly one production `invoke` without
`--preflight` and one with; and it captures the invoke's status with errexit
disabled.

### The mutation, proved by reconstruction

Removing `CINV-000003.yaml` from the post-Stage-1 fixture and rewinding
`capability-invocation.seq` to 2 reproduces the pre-Stage-1 store exactly — so
no other file differs by a byte.

### Fail closed

Seventeen block sabotages, seven work-area breakages, eleven verdict cases and
three exit-code cases. Every one must refuse **for its own reason** and must not
crash.

| sabotage | refusal |
| --- | --- |
| witness absent / wrong image | run BLOCK A first / does not record the expected image |
| witness stale / future-dated | re-run BLOCK A / dated in the future |
| advertisement expired | CADV-000007 is EXPIRED at the current clock |
| admission expired | the admission of CINST-000006 closed |
| route head moved | CROUTE-0006 no longer routes to exactly CINST-000006 |
| selection changed | CSEL-000004 does not resolve through CROUTE-0006 |
| `inspect` fails | could not inspect CADV-000007 |
| eligibility false / evaluator fails | not eligible at the current clock / compute-eligibility failed |
| Fabric or runtime baseline moved | the … store has moved |
| CINV or CRES sequence moved | capability-*.seq is N, expected M |
| Trust invalid / validator fails | does not validate / could not be validated |
| CINV-000003 already present | already exists; Stage 1 has already run |
| work root mode / payload mode / second hard link | required 700 / required 600 / hard links, required 1 |
| payload raw or canonical digest changed | the payload raw digest is … |
| payload or work root absent | is absent or not a regular file / Stage 0 has not been performed |
| preflight refuses / predicts another identity | would not accept / predicts CINV-000004 |
| verdict: status, reason, identity, invocation id, any digest, staged path, a CRES, a consumed replay, non-JSON | each by name, each with STOP AND REPORT |
| process rc 0, 2 or 137 | the process exited N … do not re-run |

**The assertion that matters most** is on every pre-invoke sabotage: the
fixture's `capability-invocation.seq` never moved and no record was written. An
identity spent in a rehearsal is an identity the gate failed to protect.

An expired advertisement stops the block before the invoke on **3 of 3** runs.

---

## 8. Test defects found and fixed

Both in the new suite, both found by running it:

**A staleness test that proved nothing.** The witness sabotage set
`WITNESS_MAXIMUM_AGE=0` against a witness written moments earlier. An age of 0
is not greater than a bound of 0, so the gate passed and the sabotage ran the
entire ceremony to completion — which the suite correctly reported as "the
block exited 0" and "AN INVOCATION IDENTITY WAS SPENT". Staleness is a property
of the witness's age, so the witness is now made old with `touch -d '3 hours
ago'`, and a future-dated witness is tested too.

**A sabotage caught by the wrong gate.** Planting `CINV-000003.yaml` in the
fixture *after* rendering the block moved the runtime aggregate, so Gate 3's
baseline check refused first — correctly, but for a different reason, and the
absence check the case exists for was never reached. The record is now planted
before rendering, so the baseline is derived from a store that already holds
it and the intended check fires.

Also removed from my own drafting: an unused variable, a no-op comparison left
in the reconstruction, and two `ls | wc -l` counts replaced with `find`.

---

## 9. Stage 0 spent mode

The Stage 0 rehearsal now branches on whether the work area exists. In the spent
state it asserts durable facts only: the work root's uid and mode, the payload's
uid, mode, link count, byte count and raw digest, that it is byte-identical to
the committed payload, that the canonical digest still recomputes to
`591d4b0d…` through the released canonicalizer, and that the committed ceremony
still pins both reviewed digests.

**It does not pin the runtime whole-store aggregate.** Stage 1 legitimately
moves it, and pinning it is the defect that broke the CINST-000006 spent mode
when CROUTE-0006 landed. What replaces it proves the same thing and survives
Stage 1: the sequences are **at or past** what Stage 0 left, and sequences are
monotonic — one that never fell below what Stage 0 left is one Stage 0 never
advanced.

---

## 10. Tests

| suite | result |
| --- | --- |
| `test-capability-cinv-000003-stage-1-rehearsal.sh` | **new** — 281 PASS, 0 FAIL |
| `test-capability-cinv-000003-stage-0-rehearsal.sh` | 0 FAIL (spent-ceremony mode) |
| `test-capability-invoke-preflight.sh` / `invoke-current-eligibility.sh` | 0 FAIL |
| `test-capability-invocation-operation-authority.sh` | 0 FAIL |
| `test-capability-execution-payload-operation-contract.sh` | 0 FAIL |
| `test-capability-execution-authority-gate.sh` / `authority-anchor` / `lifecycle` / `quota` / `duplicate-result-gate` / `protocol` / `mutation` / `recovery-discovery` | 0 FAIL |
| `test-capability-runtime.sh` | 0 FAIL |
| `test-capability-fabric.sh` / `route-head` / `preflight` / `g11-integrity` | 0 FAIL |
| `test-trust-plane.sh` / `test-trust-runtime.sh` | 0 FAIL |
| all four freeze suites | 0 FAIL |
| `test-static.sh` | 0 FAIL |
| `tools/dev/run-shellcheck.sh` | clean, exit 0 |

Four ShellCheck `SC2016` findings on the new suite are suppressed in-script
with justifications, per the workflow's stated policy: all are sed **addresses**
matching literal `${...}` text in the rendered block — text to find, not
expressions to evaluate.

Registered in `tests/host-only.manifest`, `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`. Validator totals re-measured by running it.

---

## 11. Remaining authority window

```
CADV-000007 valid_until      2026-09-23T06:00:00-05:00
CINST-000006 admitted_until  2026-09-23T06:00:00-05:00
now                          2026-09-20T~07:00-05:00
remaining                    ~2 days 23 hours
```

Stages 1, 2 and 3 all have to fit inside it. Gate 1 refuses rather than extends
when it closes.

## 12. Actions NOT performed

```
Stage 1 against production            NOT performed
CINV-000003                           NOT allocated in production
authorise-launch                      NOT run
execute                               NOT run
CRES for CINV-000003                  NOT created
the execution container               NOT started
the execution image                   NOT pulled, built, loaded or retagged
the Stage 0 payload                   NOT rewritten
Fabric / Trust / Artifact authority   unaltered
Platform Evidence                     unaltered
runtime                               not reinstalled
sudoers                               not modified
Root Authority                        not mounted
ENG-0006 / TrustGateway cutover       not begun
```

Executable Stage 2 and Stage 3 ceremonies are deliberately **not** prepared.
Stage 2's baseline is the runtime store as Stage 1 leaves it, and that store
does not exist until Stage 1 has been performed and accepted.

## 13. Production no-mutation proof

Measured at the start and again at the end, after every rehearsal and every
sabotage:

```
/var/lib/kyri/fabric          a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5   unchanged
/data/kyri/capability-runtime 159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc   unchanged
capability-invocation.seq     2      capability-result.seq  1
CINV-000003                   absent
/data/kyri/work/g11bcn-stage-1-witness   absent
/data/kyri/work/g11bcn/third-invoke.json unchanged at d01faccc…, 0600, one link
```

## 14. Known risks

**The window is the binding constraint.** Under three days remain, with three
stages to go, and Stage 3 is the one that has failed before on this chain's
predecessors.

**BLOCK A is not rehearsed.** It needs the `kyri-capability` account through
`sudo`, which this session does not have and a test may not assume. Its logic is
simple and its output is a witness BLOCK B re-checks, but the container and
image commands themselves are first exercised by the operator. The reviewer's
correction — running from `/tmp` — is built in.

**The witness is a record, not a guarantee.** It says the observation was made
and what it concluded. It cannot prove the container set has not changed in the
seconds since. The 900-second bound is what keeps the gap small; it is a bound,
not a lock.

**The record SHA cannot be pinned.** `requested_at` makes the bytes
run-dependent. The fields are pinned instead, which is what the reviewer can
match on, but a reviewer expecting a SHA should know why there is not one.

**A refusal after the invoke is not recoverable by re-running.** The identity is
spent. The ceremony says so at every post-invoke refusal, but it is worth
stating here too: the correct response is to stop and report, and let
`capability recover` enumerate the unresolved invocation.

## 15. Readiness for Stage 1

The ceremony is committed, gated six times before the irreversible command,
rehearsed whole against a fixture including the real write, and proved to fail
closed at every stage with a stated reason and without spending an identity.
The chain it rests on is complete and currently eligible, and Stage 0's output
is exactly as accepted.

What remains is the reviewer's verification of Stage 1 authority, and then a
single operator Stage 1 — BLOCK A, then BLOCK B — which allocates CINV-000003
and stops.
