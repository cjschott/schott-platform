# G11-BC-U — Stage 1 verified; Stage 2 is blocked by execution capacity

ENG-0005. 2026-09-20. Branch `arch/eng-0005-execution-transition`.

CINV-000003 Stage 1 was verified independently of the reviewer's report. Every
persisted field, the observed record SHA, both sequences and the measured
mutation agree exactly.

**Stage 2 was NOT prepared, and this checkpoint stops.** Rehearsing
`authorise-launch` against a byte copy of the production runtime found that the
released capacity module refuses it:

```
CapacityExhausted: all 2 execution slots are held
```

Both slots are held by CINV-000001 and CINV-000002, both stuck at
`launch_authorized`, and **no released surface can free either one**. §6
establishes this from the implementation. Resolving it is an architecture and
authority decision, not an implementation one, so no Stage 2 ceremony was
written.

Nothing was performed against production.

---

## 1. Starting source authority

| | |
| --- | --- |
| HEAD at start | `7c543836c760b276eceec4a052059cf2649c8503` |
| required source authority | `7c543836c760b276eceec4a052059cf2649c8503` ✔ |
| branch | `arch/eng-0005-execution-transition` ✔ |
| origin | contains HEAD at the same commit ✔ |
| working tree | clean; nothing staged, nothing untracked ✔ |
| G11-BC-T report | present ✔ |
| Stage 1 ceremony artifact | present ✔ |

## 2. Live governed authority

```
fabric aggregate   a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5   ✔
fabric validate    status reported, findings [], CADV 7 / CINST 6 / CROUTE 6 / CSEL 4
trust              valid true, problems []
root authority     not mounted (directory readable; no mount entry)
```

| record | observed |
| --- | --- |
| CADV-000007 | `2026-09-19T06:00:00-05:00` → `2026-09-23T06:00:00-05:00` |
| CINST-000006 | `admitted`, rests on CADV-000007, until `2026-09-23T06:00:00-05:00` |
| CROUTE-0006 | `route_version 6`, routes to `[CINST-000006]` |
| CSEL-000004 | through CROUTE-0006 v6, selects CINST-000006, considered `[CINST-000006]`, excluded `[]` |

Current eligibility at `2026-09-20T12:35-05:00`: **true, 12 of 12 met, unmet
[]**. The chain is operationally fresh.

Runtime, Platform Evidence and Artifact authority match G11-BC-T's aggregates
(`70011c72…`, `62c87585…`, `ef4297c6…`).

---

## 3. Stage 1, independently verified

### BLOCK A observation, as accepted

No `kyri-CINV-000003` container, no `kyri-CINV-*` container, execution image
`5cee2b53…` present as `localhost/kyri-capability-execution:g5`. The witness
survives at `/data/kyri/work/g11bcn-stage-1-witness`, 128 bytes, mode 0600,
carrying exactly the two lines BLOCK B requires.

### The six gates

All passed at invocation time: the observation witness fresh; CADV-000007
fresh with CINST-000006's admission open and ~65h25m remaining; CROUTE-0006
routing to exactly CINST-000006; CSEL-000004 binding that route and instance;
current eligibility 12/12; both store aggregates and both sequences exact with
CINV-000003 absent and Trust valid; the Stage 0 work area at its reviewed
properties and both payload digests; and the released preflight agreeing on
`would_accept`, the predicted identity, the payload digest and the resolved
selection, instance, package and operation.

### Process rc semantics

`command_invoke` ends with an unconditional `return EXIT_DENIED`, and
`EXIT_DENIED = 1`. It supplies neither adapter nor execution binding, so
nothing can execute and the verdict is `prepared` / `no_authorised_adapter`.
**rc=1 is the success code; the JSON is the verdict.** The ceremony required rc
to be exactly 1 and got it.

### The production verdict

```
process rc              1
status                  prepared
reason                  no_authorised_adapter
invocation_id           g11bcn-third-controlled-invoke
invocation_record_id    CINV-000003
result_record_id        null
payload_digest          sha256:591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
binding_digest          sha256:6d5a8d9249c7c9407145a69b55748136020a1a696c2e167d879864dc2dc86289
artifact_digest         sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
staged_path             /data/kyri/capability-runtime/staging/tree-sha256-6f2282c5…
```

### The persisted record

`/data/kyri/capability-runtime/capability-invocations/CINV-000003.yaml`

```
sha256  c0941b7d45dcccac4bb28d00f942ea63aa90cd46ed55767797363f1ed1accaf2   ✔ matches reviewer
bytes   988                                                               ✔
mode    0600   cschott:cschott                                            ✔
```

Read back field by field: `actor primary-platform-operator`,
`adapter_identity null`, the three digests as reviewed, `capability_id
CAPDEF-0001`, `capability_package_id CPKG-0001`, `contract_id CCON-0001`,
`effect_class computational`, `evidence.outcome execution-prepared`,
`evidence.request_id g11bcn-third-production-invoke`, `evidence.selection_id
CSEL-000004`, `instance_id CINST-000006`, `invocation_id
g11bcn-third-controlled-invoke`, `invocation_record_id CINV-000003`, `kind
capability-invocation`, `operation execute`, `request_id
g11bcn-third-production-invoke`, `schema_version 2`, `selection_id
CSEL-000004`, `staged_path` the reviewed staged tree. **Every value matches.**

`requested_at` is `2026-09-20 12:34:11-05:00` — the field that made the SHA
unpredictable before the write and that makes it a durable observed fact now.

### Sequences, absences and staging

```
capability-invocation.seq   2 -> 3          capability-result.seq   1 (unchanged)
CRES-000002                 absent
execution state for CINV-000003             absent
staging                     one commitment, tree-sha256-6f2282c5… — reused, not rebuilt
Fabric                      unchanged at a87c2010…
```

### Mutation accounting

By content. The live runtime store was copied, `CINV-000003.yaml` removed and
`capability-invocation.seq` rewound to 2. The canonical aggregate of that
reconstruction is:

```
159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc
```

exactly the accepted pre-Stage-1 aggregate — so **no other file differs by a
byte**. The complete Stage 1 mutation was:

1. creation of `capability-invocations/CINV-000003.yaml`;
2. advancement of `capability-invocation.seq` from 2 to 3.

The renormalisation was validated against an unmodified copy first, which
reproduced the live aggregate exactly.

### Post-Stage-1 runtime baseline

```
6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f
```

with `capability-invocation.seq 3`, `capability-result.seq 1`, CINV-000003 at
`c0941b7d…`, CRES-000002 absent and no execution state for CINV-000003.

---

## 4. The released Stage 2 contract

Read from `command_authorise_launch` (`tools/capability/cli.py`),
`authorise_launch` (`tools/capability/execution/launch.py`), `publish_handoff`
(`handoff.py`), `capacity.py` and `state.py`, and the accepted CINV-000001 /
CINV-000002 Stage 2 ceremonies.

### Command

```bash
python3 -m tools.capability.cli authorise-launch \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000003 --cimp CIMP-000001 \
  --approved-payload-root /data/kyri/work/g11bcn \
  --payload-file third-invoke.json \
  --package-entrypoint main.py
```

**Seven arguments and no store roots.** `CAPABILITY_RUNTIME_ROOT`,
`HANDOFF_ROOT` (`/data/kyri/capability-handoff`) and `AUTHORITY_ROOT` are
compiled-in constants, and the module states there is "no environment value".
Each is opened through `_anchored`, which verifies the backing store against
`/etc/kyri/backing-store.json` — so a root must be on the XFS filesystem
mounted at `/data`.

The package tree is taken from the prepared record's own `staged_path`, never
from an argument: *"An operator able to name it would be an operator able to
name a different one."*

### Verdict

`rc = 0` (`EXIT_SUCCESS`) — unlike Stage 1. Emits `cinv`, `cimp`,
`lifecycle_state: launch_authorized`, `profile_digest`, `commitment_digest`,
`package_digest`, `payload_digest`, `handoff_published`, `resumed`.

### What it does and does not touch

| | |
| --- | --- |
| mutates CINV-000003 | **no** — `launch.py` contains no `write_atomic` and no `path_for` |
| allocates a sequence | **no** — no `allocate_id` anywhere on the Stage 2 path |
| creates a CRES | **no** |
| creates execution state | **yes** — the lifecycle transition, the capacity reservation and the journalled projection |
| creates a separate launch-authority file | **yes** — `execution/CINV-000003/launch-authorisation` |
| publishes a handoff | **yes** — `/data/kyri/capability-handoff/CINV-000003/` |
| starts a container | **no** — that is Stage 3 |

Measured from CINV-000002's Stage 2, the mutation is:

```
/data/kyri/capability-runtime/execution/CINV-000003/                 0700
/data/kyri/capability-runtime/execution/CINV-000003/launch-authorisation  0600
/data/kyri/capability-runtime/execution/transitions/CINV-000003.000001    reserved
/data/kyri/capability-runtime/execution/transitions/CINV-000003.000002    launch_authorized
/data/kyri/capability-runtime/execution/locks/CINV-000003                 0 bytes
/data/kyri/capability-handoff/CINV-000003/                           0555
/data/kyri/capability-handoff/CINV-000003/profile                    0444
/data/kyri/capability-handoff/CINV-000003/payload                    0444
/data/kyri/capability-handoff/CINV-000003/package/main.py            0444
/data/kyri/capability-handoff/CINV-000003/out/                       created by Stage 2 as cschott
```

`out/` is created by `publish_handoff` as the coordinator; its ownership
transfer to `kyri-capability` is a **Stage 3** effect, which is why
CINV-000002's is owned by that account today.

### Bindings and rechecks

- **CINV-000003** must be readable and `evidence.outcome == execution-prepared`
  with a non-empty `staged_path`, or `LaunchRefused`.
- **The payload** is re-presented as a descriptor, validated through the
  governed schema, and `invocation_payload_digest(document)` must equal the
  record's `payload_digest` — *"a different payload is a different binding and
  may not borrow this authorisation."*
- **The commitment digest** is the prepared record's `binding_digest` with the
  `sha256:` prefix removed after being proved present — not a second digest.
- **The profile** is re-derived from the implementation authority
  (`authorise_implementation`), never carried across from preparation.
- **Trust and current eligibility are NOT rechecked here.** Eligibility was
  decided at Stage 1. That is the released design, and it is why the operator
  ceremony has to carry the current-authority checks itself.

### Idempotence and recovery

If the lifecycle is already `launch_authorized`, Stage 2 returns
`resumed: true`, makes no new transition, and verifies the existing handoff
rather than republishing it. Any other non-`reserved` state refuses:
`"{cinv} is {state} and is no longer awaiting launch authorisation"`.

`publish_handoff` builds under a staging name and installs with one rename, so
a partial tree can never be mistaken for a handoff, and it refuses rather than
replacing an existing one.

### Successful stop before Stage 3

`rc=0`, `lifecycle_state launch_authorized`, the handoff published and
verified, CINV-000003 byte-identical, both sequences unchanged, no CRES, no
container.

---

## 5. Stage 2 rehearsal, and what it found

The CLI's roots are compiled in, so Stage 2 **cannot be redirected to a scratch
store through the CLI**. The released `authorise_launch()` however takes
`store`, `execution_root`, `handoff_root` and `authority_fd` as parameters, so
the governed logic was driven directly against scratch roots — a byte copy of
the production runtime and an empty handoff root, both created under `/data` so
they pass the backing-store verification the real roots pass. Only the CLI's
own twenty lines of root-opening were not exercised.

It refused, at the first mutation:

```
tools.capability.execution.capacity.CapacityExhausted: all 2 execution slots are held
```

Production was byte-identical before and after, and the scratch area was
removed.

---

## 6. Why Stage 2 cannot proceed

### The rule

`capacity.py`: **two slots, no queue.**

```python
MAXIMUM_SLOTS = 2
CAPACITY_CONSUMING_STATES = tuple(s for s in LifecycleState if s is not LifecycleState.RELEASED)
```

Every lifecycle state except `released` holds its slot, deliberately: *"a slot
stays held until the invocation is finished with, which is what makes two stuck
quarantines able to halt new execution rather than silently oversubscribing the
host."*

### The state

Queried read-only against the production execution root:

```
CINV-000001   launch_authorized   consumes a slot: True
CINV-000002   launch_authorized   consumes a slot: True

MAXIMUM_SLOTS = 2      slots held = 2      free slots = 0
```

- **CINV-000001** — no terminal result, `adapter_identity: null`. Its Stage 3
  never completed (G11-BB-D).
- **CINV-000002** — resolved by CRES-000001 with `outcome_class:
  provider-error` (G11-BC-I), but its lifecycle never advanced past
  `launch_authorized`.

### Why neither slot can be freed

The lifecycle is strictly linear:

```
LAUNCH_AUTHORIZED -> {CREATED}        ... -> COLLECTED -> CLEANED -> RELEASED
```

`capacity.release()` requires a transition to `RELEASED`, and `RELEASED` is
reachable **only from `CLEANED`**. Confirmed by running the released
`release()` against the scratch copy:

```
refused: InvalidTransition: launch_authorized -> released is not a permitted transition
```

And nothing else frees one. `capacity.release` says so directly: *"Only a
lifecycle that has reached `cleaned` may release. Nothing else frees a slot:
not a vanished process, not a missing container, not an elapsed timeout, and
not a caller simply asking."*

- **`capability recover` cannot help.** *"It writes nothing. No result is
  synthesised for an interrupted invocation and the invocation record is never
  touched."* It resolves containers, not lifecycle state.
- **There is no administrative escape.** The operator CLI exposes exactly
  `{invoke, inspect, validate, authorise-launch, execute, recover}`.
  `execution/admin.py` is not among them, and it states: *"There is no shell,
  no Podman argv, no caller path, no caller-supplied identity, no repair, and
  no force… A generic delete or cleanup verb would make every narrowing above
  it decorative, so none exists."*

### What that leaves

Freeing a slot requires driving an existing invocation from
`launch_authorized` all the way to `cleaned` and then `released` — which means
**executing it**. For CINV-000002 that is additionally blocked: `execute`
begins with `require_no_terminal_result`, and CINV-000002 already has
CRES-000001.

**This is not a defect to be worked around, and it was not worked around.** It
is the capacity design doing exactly what it says it does. The decision about
how to reclaim these two slots — complete CINV-000001's lifecycle, introduce a
governed remediation, or something else — is an architecture and authority
decision. This checkpoint reports it and stops.

---

## 7. Why no Stage 2 ceremony was written

Preparing `provisioning/execution/g11-bc-n-cinv-000003-stage-2-ceremony.txt`
now would be preparing executable authority for a command the released code
will certainly refuse. Its gates would pass — the chain is fresh and eligible,
every digest is exact, the record is intact — and it would then fail at the
first mutation, having proved nothing except what §6 already proves more
cheaply.

Worse, its shape depends on the unmade decision: if a slot is freed by
completing CINV-000001, the Stage 2 baseline is a runtime store that does not
exist yet, and a ceremony pinning today's aggregate would be stale before it
was reviewed. Stage-specific baseline discipline is what this project has held
to since G11-BC-Q, and it applies here.

No architecture was changed to make a Stage 2 ceremony possible.

---

## 8. Stage 1 spent mode

The Stage 1 rehearsal now branches on whether CINV-000003 exists. In the spent
state it asserts durable facts only:

- the record at its **observed** SHA `c0941b7d…`, 988 bytes, mode 0600 — a SHA
  that could not be predicted before the write because `requested_at` carries
  the operator's clock, and that cannot change afterwards because the record is
  immutable;
- all seventeen reviewed fields, including `adapter_identity: null`;
- `capability-invocation.seq` **at or past** 3, since sequences are monotonic;
- no result record;
- the Stage 0 payload still at its reviewed digest, mode and link count —
  which matters because Stage 2 re-presents it and checks it against this
  record's `payload_digest`;
- the committed ceremony still pinning the reviewed digests.

**It does not pin the runtime whole-store aggregate.** Stage 2 legitimately
writes lifecycle state, a projection and a handoff.

One stale assertion was found and moved while doing this: the suite checked the
**pre**-Stage-1 runtime aggregate before the spent branch, which Stage 1 moves
by design. It now runs on the unspent path only — the same staleness class the
spent mode exists to prevent, caught one level up.

---

## 9. Tests

| suite | result |
| --- | --- |
| `test-capability-cinv-000003-stage-1-rehearsal.sh` | 0 FAIL (spent-ceremony mode) |
| `test-capability-cinv-000003-stage-0-rehearsal.sh` | 0 FAIL (spent) |
| `test-capability-invoke-preflight.sh` / `invoke-current-eligibility.sh` | 0 FAIL |
| `test-capability-execution-authority-gate.sh` / `authority-anchor` / `lifecycle` / `quota` / `capacity` / `duplicate-result-gate` | 0 FAIL |
| `test-capability-execution-launch-bridge.sh` / `launch-cli` | 0 FAIL |
| `test-capability-runtime.sh` / `test-capability-fabric.sh` | 0 FAIL |
| `test-trust-plane.sh` / `test-trust-runtime.sh` | 0 FAIL |
| `test-static.sh` | 0 FAIL |
| `tools/dev/run-shellcheck.sh` | clean, exit 0 |

No new suite was added, because no new artifact was prepared.

---

## 10. Remaining authority window

```
CADV-000007 valid_until      2026-09-23T06:00:00-05:00
CINST-000006 admitted_until  2026-09-23T06:00:00-05:00
now                          2026-09-20T~13:00-05:00
remaining                    ~2 days 17 hours
```

The window is now the second constraint rather than the first. Stages 2 and 3
must fit inside it **after** the capacity question is answered, and answering
it may itself consume a ceremony.

## 11. Actions NOT performed

```
Stage 2 against production            NOT performed
Stage 2 ceremony                      NOT prepared -- see §7
Stage 3 / execute                     NOT run
the payload                           NOT executed
CRES                                  NOT created
the execution container               NOT started
the image store                       NOT modified
Stage 1                               NOT re-run
lifecycle state                       NOT altered for any invocation
Fabric / Trust / Artifact authority   unaltered
Platform Evidence                     unaltered
runtime                               not reinstalled
sudoers                               not modified
Root Authority                        not mounted
ENG-0006 / TrustGateway cutover       not begun
```

The rehearsal created a scratch runtime and handoff root under
`/data/kyri/g11bcu-stage2-rehearsal`, outside every governed store, and removed
it. Its only effect was one empty lock file inside itself.

## 12. Production no-mutation proof

Measured at the start and again at the end:

```
/var/lib/kyri/fabric          a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5   unchanged
/data/kyri/capability-runtime 6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f   unchanged
capability-invocation.seq     3      capability-result.seq  1
/data/kyri/capability-handoff CINV-000001, CINV-000002 only
execution state               CINV-000001, CINV-000002 only
CINV-000003                   c0941b7d… unchanged
Stage 0 payload               d01faccc… unchanged, 0600, one link
```

## 13. What the reviewer is being asked to decide

Not whether Stage 2 is correctly prepared — it is not prepared. The question is
how the two held execution slots are to be reclaimed, given that:

1. the released surface has no path from `launch_authorized` to `released`;
2. `recover` writes nothing and `admin` has no repair or force verb;
3. CINV-000001 could in principle be driven forward, but that is Stage 3 on an
   invocation whose Stage 3 has failed before;
4. CINV-000002 cannot be driven forward at all, because `execute` refuses an
   invocation that already has a terminal result;
5. raising `MAXIMUM_SLOTS` is an architecture change and was not made.

Once that is decided, Stage 2 can be prepared against the runtime baseline that
decision leaves behind.
