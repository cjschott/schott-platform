# ENG-0005 G11-BB-Y — CINV-000002 Stage-1 acceptance, and Stage-2 preparation

**Status: `CINV-000002` is allocated, immutable, and verified against the
reviewed bytes. All three digest bindings are recomputed independently and match.
Stage 2 is prepared and its expected output derived read-only from installed
source. Nothing was authorised, published or executed.**

```
CINV-000002    923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   as reported
CINV_COUNT 2   CRES_COUNT 0   INVOCATION_SEQ 2   next CINV-000003 / CRES-000001
STAGED_TREE    PASS       staged main.py byte-identical to the governed artifact
STAGE2_PREPARED YES       STAGE2_AUTHORISED NO   STAGE3_AUTHORISED NO
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. The immutable record

```
invocation_record_id    CINV-000002
invocation_id           g11bb2-second-controlled-invoke
selection_id            CSEL-000003        instance_id  CINST-000004
capability_package_id   CPKG-0001          capability_id  CAPDEF-0001
contract_id             CCON-0001          operation    execute
effect_class            computational      schema_version  2
actor                   primary-platform-operator
request_id              g11bb2-second-production-invoke
requested_at            2026-09-09 11:50:22-05:00
adapter_identity        null
staged_path             /data/kyri/capability-runtime/staging/tree-sha256-6f2282c5…

evidence.outcome        execution-prepared
evidence.actor          primary-platform-operator
evidence.request_id     g11bb2-second-production-invoke
evidence.selection_id   CSEL-000003

CINV_SHA256             923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   MATCHES
```

### 1.1 CLI `status` and the governed record outcome are different constants

The authorisation was right to warn about this. They are two vocabularies:

```
evidence.py  STATUS_PREPARED   = "prepared"            <- the CLI's response field
evidence.py  OUTCOME_PREPARED  = "execution-prepared"  <- what the RECORD stores

CINV-000002 evidence.outcome = 'execution-prepared'
```

The operator's Stage-1 JSON said `status: prepared`; the durable record says
`outcome: execution-prepared`. Both are correct, and **the record's value is the
one Stage 2 gates on** — `_prepared_invocation` compares against
`PREPARED_OUTCOME`, the record constant.

`result_record_id` is likewise **not a field of the invocation record at all**:
`'result_record_id' in INVOCATION_FIELDS` is `False`. The Stage-1 JSON's
`result_record_id: null` is a CLI response field, and its absence from the record
is the record being correctly shaped, not a value missing from it.

`adapter_identity: null` is a real record field and is the one that makes an
unresolved invocation legible later: nothing was ever authorised to run, so an
absent result means nothing was attempted.

## 2. Digest bindings, recomputed independently

Every value recomputed from released code against the payload as it sits on disk:

| | value | verdict |
| --- | --- | --- |
| **raw source SHA256** | `e12a525c289458f49ae1f5ae073ac97aac927627f15ac2a2450557f4cad65127` | MATCH |
| **`payload_digest`** | `sha256:e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c` | MATCH — `invocation_identity.payload_digest` |
| **`binding_digest`** | `sha256:58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da` | MATCH — `invocation_identity.bind(...)` over payload + invocation + selection + instance + package + operation + actor |
| **`artifact_digest`** | `sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e` | MATCH — the governed package tree |

**Raw and governed remain distinct and must not be conflated:**

```
raw source SHA256          e12a525c…    283 bytes as written on disk
governed payload_digest    e2914a90…    254 canonical bytes
equal?                     False
```

Reformatting the file changes the first and not the second — proved in §8, N2c.

```
/data/kyri/work/g11bb2                    cschott:cschott  700
/data/kyri/work/g11bb2/second-invoke.json cschott:cschott  600  283 bytes
```

The payload was not mutated by this checkpoint.

## 3. The staged tree

```
dr-x------ cschott:cschott  .../staging/tree-sha256-6f2282c5…            (0500)
-r-------- cschott:cschott  .../staging/tree-sha256-6f2282c5…/main.py    (0400, 8192 bytes)

staged   main.py  683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd
governed main.py  683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd
                  /var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0/main.py
BYTE-IDENTICAL
```

Read-only and non-editable by the coordinator: the tree is `0500`, the entrypoint
`0400`. `main.py` is the sole member.

**Stage 1 did not re-stage — it reused.** The tree's mtime is
`2026-09-04 19:30:54`, from `CINV-000001`'s Stage 1. The staging path is
content-addressed by `artifact_digest`, both invocations bind the same governed
package, so the same digest is the same path; `package_resolution` checks the
digest and ownership before reusing. No staging write occurred at Stage 1 for
`CINV-000002`, which is why the staging tree carries the older timestamp and
should not be read as stale.

```
STAGED_TREE = PASS
```

## 4. History and sequences

```
validate_store findings   ()
CINV_COUNT   2      CRES_COUNT   0
invocation sequence  2       next CINV-000003
result sequence      ABSENT  (no capability-result.seq file)   next CRES-000001
CINV-000003          does not exist

CINV-000001  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa  BYTE-IDENTICAL
             outcome execution-prepared, adapter_identity null -> permanently UNRESOLVED
             resume FORBIDDEN
```

The result sequence file has never been created, which is the store's designed
shape: `peek_next_id` reads an absent sequence as zero rather than provisioning
it, so `CRES-000001` is still the next result identity.

## 5. Fabric, Trust, and chain freshness

```
CADV_HEAD CADV-000005   CINST_HEAD CINST-000004   CROUTE_HEAD CROUTE-0004
CSEL-000003 binds route CROUTE-0004 v4, instance CINST-000004

fabric  valid, findings []      3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b
trust   valid, problems []      53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f
```

**Operational observation only:** re-evaluated now, `CINST-000004` is still
eligible with no unmet conditions, and the lease has **1 day 9 h** left. This
changes nothing about `CINV-000002` — its eligibility decision was made and made
durable at Stage 1, at `requested_at 2026-09-09 11:50:22-05:00`, and neither
Stage 2 nor Stage 3 re-asks (G11-BB-X §2.1). The window is reported because an
operator should know it, not because the remaining stages depend on it.

## 6. Supervision readiness

```
coordinator_identity_authority true    execution_identity_authority true
execution_identity_account     kyri-capability
helper_compatibility  compatible       helpers_blocking  []
supervision_ready     true
launch_grant   unobservable            reconcile_grant   unobservable
```

```
/etc/sudoers.d/kyri-exec-launch      -r--r----- root:root  482  PRESENT, contents unreadable
/etc/sudoers.d/kyri-exec-reconcile   -r--r----- root:root  487  PRESENT, contents unreadable
/etc/sudoers.d/kyri-exec-verify                                 ABSENT
```

**Both grants exist and the verification grant is absent — that much the
directory listing shows. Whether each grant pins the installed entrypoint by
digest is not observable to me**, which is why the released surface says
`unobservable` rather than guessing. Image presence is likewise operator
evidence: the execution identity's store is `kyri-capability:kyri-capability 750`
and the preflight's `execution_image_available: false` is coordinator blindness,
not absence (G11-BB-X §3.2). The operator's own pre-Stage-1 observation recorded
the image at `5cee2b53…`, and the implementation authority declares the same id
(§8).

## 7. Stage 2 — the command, and what it should do

Derived from the installed parser, which takes exactly seven arguments and no
store roots — every root is compiled in.

```bash
# STAGE 2 -- authorise the launch for CINV-000002. Publishes the handoff.
# Runs UNPRIVILEGED: it does not load the helper and does not cross the
# privilege boundary. EXPECT rc=0.
cd /opt/schott-platform
python3 -m tools.capability.cli authorise-launch \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000002 \
  --cimp CIMP-000001 \
  --approved-payload-root /data/kyri/work/g11bb2 \
  --payload-file second-invoke.json \
  --package-entrypoint main.py ; echo "rc=$?"

# Then capture, before anything else:
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000002.yaml
#   require UNCHANGED: 923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
cat /data/kyri/capability-runtime/sequences/capability-invocation.seq
#   require 2 -- Stage 2 allocates nothing
ls /data/kyri/capability-runtime/capability-results/ | wc -l
#   require 0
find /data/kyri/capability-handoff/CINV-000002 -printf '%M %u:%g %s %p\n' | sort
cat /data/kyri/capability-runtime/execution/transitions/CINV-000002.*
```

The **same** payload file that Stage 1 used is presented again; its digest binds
the two stages.

### 7.1 Expected output, derived read-only

Every digest below was computed against production without writing anything, by
calling the same released functions Stage 2 will call:

```
EXPECTED_STAGE2_RC          0                       <- EXIT_SUCCESS, unlike Stage 1
cinv                        CINV-000002
cimp                        CIMP-000001
lifecycle_state             launch_authorized
handoff_published           true
resumed                     false
profile_digest              b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923
commitment_digest           58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da
payload_digest              e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c
package_digest              6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
```

Also derived, and not emitted by the command: `adapter_identity
python-podman-v1`, `oci_image_id 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190`.

**`commitment_digest` is the binding digest, in bare form.** The released rule is
that the commitment *is* the prepared invocation's `binding_digest` with the
`sha256:` prefix removed after being proved present — not a second digest over
the same facts.

**`resumed: false`** because `CINV-000002` has no lifecycle state yet: the
transitions directory holds only `CINV-000001.000001` and `CINV-000001.000002`.
The state machine takes the `current is None` branch — reserve, then transition
`RESERVED → LAUNCH_AUTHORIZED`.

**`rc=0` is the success code here, unlike Stage 1**, where `command_invoke`
returns `EXIT_DENIED` unconditionally. `command_authorise_launch` ends with
`return EXIT_SUCCESS`.

### 7.2 Stage 2 cannot allocate another CINV

Mechanical, not argued. `authorise_launch` in `launch.py` contains **no**
`allocate_id`, **no** `record_invocation`, **no** `peek_next_id` and **no**
`write_atomic` — a grep for all four returns nothing. Its only contact with the
invocation store is `store.read_record(...)` via `_prepared_invocation`, whose
docstring says the record "is read rather than reconstructed". The immutable
`CINV-000002` bytes are therefore untouched by Stage 2, and
`capability-invocation.seq` must still read `2` afterwards.

## 8. Negative and safety battery

Read-only, against production records and fixture roots. **The real payload was
never modified**, no `CINV` or `CRES` was allocated, and no handoff was published.

**The prepared-invocation gate**

| # | input | verdict |
| --- | --- | --- |
| — | `CINV-000002` | accepted |
| N1b | `CINV-000009` (does not exist) | refused — `is not a readable invocation` |
| N1c | `not-a-cinv` (malformed) | refused — `identifier is not valid` |
| **N1** | **`CINV-000001`** | **ACCEPTED by this gate** — see below |

**N1 is the one that does not refuse where you would expect.** `CINV-000001`
also carries `outcome: execution-prepared` and a `staged_path`, so the record
gate admits it. What actually stops a `--cinv` typo is **the payload binding**:

```
CINV-000001 payload_digest   sha256:0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec
CINV-000002 payload_digest   sha256:e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c
Stage-0 payload presents     sha256:e2914a90…
  against CINV-000001  ->  REFUSED: the presented payload is not the one CINV-000001 was prepared with
  against CINV-000002  ->  ACCEPTED
```

So the reviewed Stage-2 command is safe against a `--cinv` typo, but by
second-order protection. Worth knowing, because **`CINV-000001` is at
`launch_authorized`** — its journal reads
`{"state":"reserved"}` then `{"state":"launch_authorized"}` — and the state
machine's `elif current is LifecycleState.LAUNCH_AUTHORIZED: resumed = True`
branch means a Stage 2 aimed at it would be treated as a **resume**, not
refused, if the payload gate did not catch it first. Running Stage 2 with
`CINV-000001` and its original payload root would re-enter that record. **Do not
substitute the `--cinv` or the `--approved-payload-root`.**

**The payload re-presentation gate** — the check `authorise_launch` performs
verbatim:

| # | presented | verdict |
| --- | --- | --- |
| — | the real Stage-0 payload | accepted |
| N2 | `arguments.count` changed to 2 | refused |
| N2b | `note` edited after review | refused |
| N2d | `CINV-000001`'s payload | refused |
| **N2c** | **same document, reflowed bytes** | **ACCEPTED** |

N2c is correct and worth stating: the gate is over the **canonical document**,
not the file bytes. A reformatted-but-identical payload passes Stage 2. The file
itself is pinned only by the raw digest the operator checked at Stage 0 — which
is why both digests are carried separately in §2.

**The package and implementation gates**

| # | input | verdict |
| --- | --- | --- |
| — | entrypoint `main.py`, `CIMP-000001` | accepted |
| N3 | entrypoint `run.py` | refused — `not a validated file in this package` |
| N3b | entrypoint `../main.py` | refused — `the entrypoint must not contain traversal` |
| N4 | `CIMP-000002` | refused — `not in the authority-set` |
| N4b | malformed CIMP | refused — `not a CIMP identity` |

**The approved-payload-root gate** (fixture roots; the real root untouched)

| # | root | verdict |
| --- | --- | --- |
| — | `/data/kyri/work/g11bb2` (0700, uid 1000) | accepted |
| N5 | other-writable `0777` | refused — `writable beyond its owner` |
| N5b | group-writable `0770` | refused — same |
| N6 | wrong expected uid (0) | refused — `not owned by the trusted uid` |
| N7 | file name traversing upward | refused — `may not traverse upward` |
| N7b | file that does not exist | refused |
| **N5c** | **world-readable `0755`** | **ACCEPTED** |

N5c is by design — the rule is *not writable* beyond the owner, not *not
readable*. Stated so "wrong ownership → refuse" is not over-read.

### 8.1 Helper incompatibility and `supervision_ready` do NOT gate Stage 2

The authorisation asked for these to refuse before the privileged boundary.
**They do not apply at Stage 2, because Stage 2 never reaches that boundary.**
`command_authorise_launch` contains no reference to `_helper_launcher`,
`supervision`, `helpers` or `compatibility` — a grep across the whole function
returns nothing. `_helper_launcher()` is called by `command_execute`, i.e. Stage
3. Stage 2 runs entirely unprivileged: it reads the store, re-presents the
payload, derives the profile from the implementation authority, commits a
lifecycle transition and publishes the handoff — all under coordinator-owned
roots.

That is consistent with the first invocation, where Stage 2 returned `rc=0` and
Stage 3 was the step that failed. **A green Stage 2 is not evidence that Stage 3
can run**, and the helper closure is what will refuse there if it must.

## 9. Expected handoff — not created

Derived from `handoff.py`'s published mode matrix and corroborated by
`CINV-000001`'s existing handoff:

```
/data/kyri/capability-handoff/CINV-000002            0555  invocation subtree
/data/kyri/capability-handoff/CINV-000002/package    0555  package directory
/data/kyri/capability-handoff/CINV-000002/package/main.py  0444
/data/kyri/capability-handoff/CINV-000002/payload    0444  the canonical payload bytes
/data/kyri/capability-handoff/CINV-000002/profile    0444  the governed execution profile
/data/kyri/capability-handoff/CINV-000002/out        0700  the governed output leaf
```

The subtree and package are readable and traversable but not writable; the
payload and profile are read-only; the output leaf is the only writable member.
Nothing under `/data/kyri/capability-handoff` was created by this checkpoint —
it still holds only `CINV-000001`.

## 10. CINV-000001 defect regression — deployment evidence only

```
kyri-exec-worker.py               2d320630…  DEPLOYED at the reviewed ef4f744 target
kyri_exec_transition_action.py    b11a2f19…  DEPLOYED
kyri_exec_quota.py                54a9b15c…  DEPLOYED
_ANCHOR_FLAGS = os.O_PATH | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY   3/3 modules
authority-directory anchor        the transition_action seam, O_PATH, deployed
recovery discovery                all_states / _container_possible / lifecycle_state
                                  present in the installed runtime's recovery.py
```

**This is deployment evidence, not proof.** That the first-invoke defect cannot
reproduce is an argument from the installed bytes and the helper ceremony's
acceptance; only Stage 3 can demonstrate it, and Stage 3 is not authorised here.

## 11. Validation

No source, test or provisioning file changed; this checkpoint adds this report
only.

```
FOCUSED STAGE-2 / LAUNCH / SUPERVISION SUITES   16 suites, 1419 assertions, 0 FAIL, 2 SKIP
  launch-bridge 31   launch-cli 26   handoff 42   handoff-root-traversal
  lifecycle 45   authority-gate 28   authority-anchor   coordinator-authority 44
  protocol 34   capacity 31   capacity-race 5   capability-runtime 1089
  helper-policy 35   helper-coherence 9
  profile-transport SKIP   transition-action SKIP   (declared host-only skips)

LOCAL_QUICK   PASS
LOCAL_FULL    PASS
GITHUB CI     6/6
CLEAN CLONE   PASS

CINV-000002    923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   unchanged
CINV-000001    1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
invocation seq 2      CRES 0      handoff holds only CINV-000001
fabric  3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b   byte-identical
trust   53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   byte-identical

NO STAGE-2 MUTATION. NO HANDOFF PUBLISHED. NO CRES CREATED.
```

## 12. STOP

```
STAGE2_PREPARED  YES        STAGE2_AUTHORISED  NO
STAGE3_AUTHORISED NO        PRODUCTION_INVOKE_AUTHORISED  NO
CINV_000001_RESUME_AUTHORISED  NO
```

Reviewer accepts this Stage-1 evidence and Stage-2 preparation; the operator then
runs **Stage 2 only** and returns the complete JSON, its exit code, the unchanged
`CINV-000002` digest, the invocation sequence, the handoff listing and the
lifecycle transitions. **Stage 3 must not follow without its own acceptance
checkpoint** — it is the step the first invocation died at.
