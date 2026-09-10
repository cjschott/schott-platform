# ENG-0005 G11-BB-Z — CINV-000002 Stage-2 acceptance, and Stage-3 preparation

**Status: Stage 2 is verified and accepted — the handoff, profile, commitment and
lifecycle all check out independently. Stage 3 is prepared but I am recommending
it NOT be authorised yet.**

**§3 asked me to reconfirm that recovery would discover `CINV-000002` if Stage 3
left it unresolved. It does not.** The lifecycle journal is keyed by the `CINV`
record id, but the enumeration looks it up by the *opaque* `invocation_id`, so
the supervised-path signature never fires for a real invocation. Both
`CINV-000001` and `CINV-000002` are currently invisible to
`unresolved_invocations`, `command recover` has no way to name an invocation
manually, and `execution_safety` inherits the blindness and reports **READY**.

```
RESULT                      STOPPED — not a Stage-2 problem; a Stage-3 recovery-path problem
HANDOFF_VERIFICATION        PASS      PROFILE_VERIFICATION  PASS
COMMITMENT_VERIFICATION     PASS      LIFECYCLE_STATE       launch_authorized
RECOVERY_DISCOVERY_FIX      FAIL   <- the blocker
STAGE3_PREPARED             YES       STAGE3_AUTHORISED     NO
```

Branch `arch/eng-0005-execution-transition`. No production state was changed.

---

## 1. Stage 2, verified independently

```
CINV-000002 sha256   923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   UNCHANGED
CINV-000001 sha256   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   UNCHANGED
invocation seq       2          CRES count  0        next CINV-000003 / CRES-000001
validate_store       findings ()
```

**Lifecycle** — the journal, read from disk:

```
CINV-000002.000001   {"previous":null,      "sequence":1, "state":"reserved"}
CINV-000002.000002   {"previous":"reserved","sequence":2, "state":"launch_authorized"}
```

**The launch authorisation binds exactly what was reviewed:**

```json
{"cimp":"CIMP-000001","cinv":"CINV-000002",
 "commitment_digest":"58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da",
 "handoff_root":"/data/kyri/capability-handoff",
 "lifecycle_state":"launch_authorized",
 "profile_digest":"b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923",
 "profile_schema_version":1}
```

`commitment_digest` re-derived by calling the released `commitment_digest()` on
the record's own `binding_digest` — `sha256:58ef2481…` → `58ef2481…` — **MATCH**.

```
COMMITMENT_VERIFICATION = PASS
```

### 1.1 The handoff, checked against released code rather than eyeballed

Modes compared field by field against `handoff.HANDOFF_MODES`:

| path | mode | expected | |
| --- | --- | --- | --- |
| `.` | `0555` | `0555` | OK |
| `./package` | `0555` | `0555` | OK |
| `./package/main.py` | `0444` | `0444` | OK |
| `./payload` | `0444` | `0444` | OK |
| `./profile` | `0444` | `0444` | OK |
| `./out` | `0700` | `0700` | OK |

```
MODE MATRIX  PASS       every member cschott:cschott
```

**Payload** — the handoff carries the *canonical* bytes, not the source file:

```
published    254 bytes   e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c
canonical    254 bytes   e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c   BYTE-IDENTICAL
source file  283 bytes   e12a525c…                                                          (raw, unchanged)
```

**Package** — three copies, one value:

```
handoff/package/main.py   683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd
governed artifact         683e25ed…      staged tree   683e25ed…      ALL THREE BYTE-IDENTICAL
```

**Profile** — re-parsed from the published bytes with `parse_canonical_profile`,
round-tripped through `canonical_profile` to identical bytes, and
re-fingerprinted:

```
re-derived profile_digest   b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923   MATCH
cinv CINV-000002   cimp CIMP-000001   adapter_identity python-podman-v1
oci_image_id 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
verify_governed_policy      PASS
```

```
HANDOFF_VERIFICATION = PASS      PROFILE_VERIFICATION = PASS
```

## 2. Execution readiness

```
helper_compatibility  compatible    helpers_blocking  []    supervision_ready  true
coordinator_identity_authority true    execution_identity_authority true
execution_identity_account  kyri-capability
launch_grant  unobservable          reconcile_grant  unobservable
```

**The entrypoints are at exactly the digests the grants are required to pin:**

```
/usr/libexec/kyri-exec-transition   0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1   MATCH
/usr/libexec/kyri-exec-reconcile    2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77   MATCH
```

**Whether the grants pin them is not observable to me.** Both grant files are
`-r--r----- root:root`; the verification grant is absent from the directory. So
the *entrypoint side* of the pin is confirmed and the *grant side* is not.

```
IMAGE_AUTHORITY            OPERATOR_CHECK_REQUIRED
PREEXEC_CONTAINER_STATE    OPERATOR_CHECK_REQUIRED
```

The execution identity's image store is `kyri-capability:kyri-capability 750`;
the preflight's `execution_image_available: false` is coordinator blindness, not
absence (G11-BB-X §3.2). The declared `oci_image_id` in the published profile is
`5cee2b53…`, matching what the operator observed before Stage 1. §7 carries the
read-only precheck.

The lease closes `2026-09-10T21:30:00-05:00`, **16 h 28 m** from this reading.
Stage 3 does not re-evaluate eligibility (G11-BB-X §2.1), so this does not gate
it — reported because an operator should know it.

## 3. First-attempt defect fixes — five PASS, one FAIL

Compared against installed bytes, not cited from prior reports.

| fix | evidence in installed bytes | |
| --- | --- | --- |
| **worker handoff anchor** | `/usr/libexec/kyri-exec-worker.py:92` `_ANCHOR_FLAGS = os.O_PATH\|O_NOFOLLOW\|O_CLOEXEC\|O_DIRECTORY`, used at `:392` on `HANDOFF_ROOT`; digest `2d320630…` = reviewed target | **PASS** |
| **execution authority directory anchor** | `kyri_exec_transition_action.py:85` same flags, `:151` `os.open(path, _ANCHOR_FLAGS)`; `:147` *"An `O_PATH` descriptor also cannot be read at all, so 'no sibling enumeration'"*; digest `b11a2f19…` | **PASS** |
| **quota anchor** | `kyri_exec_quota.py:66` same flags, `:164` on `HANDOFF_ROOT`; digest `54a9b15c…` | **PASS** |
| **reconciliation authority anchor** | `/usr/libexec/kyri-exec-reconcile:65` and `kyri-exec-reconcile-worker.py:42` both `ACTION_MODULE = "kyri_exec_transition_action"` — the reconciliation path opens roots through the same corrected seam | **PASS** |
| **reconciliation diagnostic stderr** | `kyri_exec_launcher.py` `MAXIMUM_REFUSAL_EXCERPT = 300`; at `:296` `excerpt = _excerpt(done.stderr)` carried into the refusal, with the comment naming the checkpoint spent recovering a message *"already produced and thrown away"* | **PASS** |
| **recovery discovery** | see §4 | **FAIL** |

### 3.1 The pinned-entrypoint digests are unchanged since G11-BA

Both entrypoints still carry the bytes the accepted grants were written against,
so no sudoers edit is implied by anything in this checkpoint.

## 4. RECOVERY_DISCOVERY_FIX = FAIL — the blocker

`unresolved_invocations` is the surface G11-BB added so that a supervised
execution which lost supervision is discoverable at all. Its docstring is right
about the intent:

> *So the supervised path is recognised by the evidence it does leave: the
> lifecycle transition journal … An invocation at or beyond `launch_authorized`
> with no terminal result is one where execution was authorised and its outcome
> was never established.*

**The key it uses to consult that journal is wrong.**

```python
def _invocation_identity(record):
    return record.get("invocation_id") or record.get("invocation_record_id")
...
identity = _invocation_identity(record)
state = states.get(identity) if isinstance(identity, str) else None
if not adapter_identity and not _container_possible(state):
    continue
```

The journal is written by `state_module.transition(execution_root, identity, …)`
where `identity` is the **`CINV`**, so its keys are `CINV-000001`,
`CINV-000002`. But `_invocation_identity` *prefers* the opaque `invocation_id`,
which on any real invocation is a descriptive string. The lookup misses, the
state reads `None`, `_container_possible(None)` is `False`, `adapter_identity` is
`None` on the supervised path — and the record is skipped.

**Measured against live production:**

```
lifecycle journal keyed by : ['CINV-000001', 'CINV-000002']

record CINV-000001   invocation_id 'g11bb-first-controlled-invoke'
   _invocation_identity() -> 'g11bb-first-controlled-invoke'
   states.get(that)       -> None                     states.get('CINV-000001') -> LAUNCH_AUTHORIZED
record CINV-000002   invocation_id 'g11bb2-second-controlled-invoke'
   _invocation_identity() -> 'g11bb2-second-controlled-invoke'
   states.get(that)       -> None                     states.get('CINV-000002') -> LAUNCH_AUTHORIZED

unresolved_invocations(store, execution_root=<real anchored root>)  ->  ()
```

Both invocations sit at `launch_authorized` with no `CRES`. **Neither is
discovered.**

**Cause isolated** — one record, three `invocation_id` shapes, journal keyed by
the `CINV`, everything else identical:

| `invocation_id` | discovered? |
| --- | --- |
| `g11bb2-second-controlled-invoke` (the real shape) | **NOT DISCOVERED** |
| `CINV-000002` (coincides with the record id) | `['CINV-000002']` |
| absent | `['CINV-000002']` |

The `or record.get("invocation_record_id")` fallback only rescues records whose
`invocation_id` is missing.

### 4.1 Why this is a stop rather than a note

**`command recover` cannot be pointed at an invocation.** Its parser takes
`--expected-uid` and `--expected-gid` and nothing else — recovery is driven
entirely by the enumeration. A blind enumeration means the governed recovery
path cannot reach `CINV-000002` at all.

**`execution_safety` inherits it, and fails open.** It calls
`reconcile_unresolved` → `unresolved_invocations`; with no findings, `blocking`
is empty and the state is `READY`. An interrupted `CINV-000002` would therefore
not block a later invocation, and the gate whose whole purpose is to promise
that a governed container belongs to exactly one live invocation would be
promising it without evidence.

**This is the same blind spot that cost the first invocation a checkpoint.**
G11-BB-D found `CINV-000001` invisible to the surface built to find it; the fix
addressed the *signal* (read the journal) and not the *key*.

### 4.2 The suite passes because its fixture is the one shape that works

`tests/test-capability-execution-recovery-discovery.sh` exists specifically to
prevent this regression, runs 10 assertions and passes. Its fixture:

```python
def invocation(cinv, adapter_identity=None):
    return {"invocation_record_id": cinv, "invocation_id": cinv,
            "adapter_identity": adapter_identity}
```

`invocation_id` is set **equal to** the `CINV`. That is the coincidental case in
the table above — the only one the buggy lookup handles. The suite exercises the
journal path faithfully and still cannot see the defect, because the fixture
encodes the same assumption as the code. Neither production invocation has that
shape.

**Recommended correction** (not applied here — this checkpoint is read-only, and
the fix is a source change that belongs in its own RED-first checkpoint): look
the journal up by `invocation_record_id`, and extend the suite's fixture so at
least one case carries an opaque `invocation_id` that differs from the record id.

## 5. Stage 3 — prepared, not authorised

Derived from the installed parser: five arguments, no roots.

```bash
# STAGE 3 -- NOT AUTHORISED. Crosses the privileged boundary and writes CRES-000001.
cd /opt/schott-platform
python3 -m tools.capability.cli execute \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000002 \
  --actor primary-platform-operator \
  --recorded-at "$(date -Is)" ; echo "rc=$?"
```

### 5.1 Expected success shape

```
EXPECTED_STAGE3_RC                   0        (EXIT_SUCCESS if terminal.succeeded)
EXPECTED_STAGE3_STATUS               terminal.status  — the T13 outcome class, non-null
EXPECTED_RESULT_RECORD_ID            CRES-000001
EXPECTED_SUCCEEDED                   true
result_digest                        non-null (required: a success with no digest is refused)
EXPECTED_RESULT_ARTIFACT_REFERENCE   null     (passed as None by command_execute)
EXPECTED_DISPOSAL_PROVEN             true     (a literal on the success path)
cinv                                 CINV-000002
invocation_record_id                 CINV-000002
reason                               terminal.reason
```

The success payload carries exactly these nine keys.

### 5.2 Fields that exist ONLY on the unresolved path

If supervision is refused, `command_execute` emits a **different** object — and
`result_recorded` is `false`, i.e. **no `CRES` is written**:

```
status              "unresolved"        <- literal
reason              str(refusal)
protocol_states     list                ONLY here
worker_reaped       bool | null         ONLY here
disposal_proven     bool | false        (present on both, but false-able only here)
reconciled          value | null        ONLY here
result_recorded     false               ONLY here
rc                  1 (EXIT_DENIED)
```

`protocol_states`, `worker_reaped`, `reconciled` and `result_recorded` **do not
appear on success**. Conversely `invocation_record_id`, `result_record_id`,
`succeeded`, `result_digest` and `result_artifact_reference` do not appear on the
unresolved path.

`rc=1` is ambiguous by itself — Stage 1 returns 1 on success too. **Read
`status`.**

### 5.3 The result contract

`record_terminal_result` never touches the invocation record: *"CINV is the
immutable pre-execution attempt evidence … Recording completion by editing it
would destroy the property that makes it worth having."* So `CINV-000002`'s
digest must be unchanged after Stage 3.

It refuses an undescribable pair — a success with no digest, or a failure
carrying one — so a fabricated success cannot be written.

```
RESULT_FIELDS = (capability_result_id, invocation_record_id, attempt_number,
                 outcome_class, reason, result_digest, result_artifact_reference,
                 started_at, ended_at, recorded_at, kind, schema_version, evidence)

'selection_id' in RESULT_FIELDS : False
'instance_id'  in RESULT_FIELDS : False
```

**Confirmed: the `CRES` carries neither `selection_id` nor `instance_id`.** They
bind transitively through `invocation_record_id` → `CINV-000002` → `CSEL-000003`
/ `CINST-000004`. The schema is closed, so adding them would be refused as
unknown fields.

### 5.4 Disposal evidence — what is surfaced versus what is enforced

| claim | where it is visible |
| --- | --- |
| container exited / terminal outcome reached | success `status` + `succeeded` |
| result admitted | `result_digest` non-null |
| **disposal proven** | success: `disposal_proven: true`, a **literal** — the success path is only reached when the supervisor concluded, so it asserts rather than reports |
| **worker reaped** | **unresolved output only** (`worker_reaped`) |
| **reconciliation outcome** | **unresolved output only** (`reconciled`) |
| **no orphaned `kyri-CINV-000002` container** | **not in either JSON** — operator observation, §7 |

So on success the JSON asserts disposal and shows nothing about the worker or the
container; the granular trace exists only when things went wrong. The container
check in §7 is the only direct evidence of no orphan, and it is the operator's.

## 6. Negative and safety battery

Read-only; no production mutation, no `CRES`, no handoff change.

| # | case | verdict |
| --- | --- | --- |
| — | `CINV-000002` at `launch_authorized` | the state the executor expects |
| N1 | wrong lifecycle state | `authorise_launch` refuses anything not `None`/`RESERVED`/`LAUNCH_AUTHORIZED`: *"is … and is no longer awaiting launch authorisation"* |
| N2 | commitment mismatch | the commitment **is** the record's `binding_digest`; a different binding is a different commitment — verified MATCH in §1 |
| N3 | payload mismatch | Stage-2 gate, exercised in G11-BB-Y §8: `count` changed, `note` edited and `CINV-000001`'s payload all refused |
| N4 | handoff profile digest mismatch | `_verify_handoff` re-verifies published bytes on a resumed authorisation; the profile round-trips and re-fingerprints to the recorded digest (§1.1) |
| N5 | helper incompatibility | `_helper_launcher()` is reached only by `command_execute`; the launcher refuses before the privileged call and the readiness gate is `compatible` with `helpers_blocking []` |
| N6 | `supervision_ready = false` | same boundary — Stage 3 is the first stage that consults it |
| N7 | wrong helper digest | the sudo grants pin by digest; the installed entrypoints match the required values (§2), and a mismatch is a sudo refusal the coordinator cannot bypass |
| N8 | missing execution image | fails closed at container verification: `profile.py` `compare("oci_image_id", profile.oci_image_id, observed.oci_image_id)` |
| N9 | worker cannot access sibling handoffs | `O_PATH` anchor: the descriptor *cannot be read at all*, so sibling enumeration is impossible by construction, not by policy (§3) |
| N10 | execution authority directory cannot be enumerated | same anchor in `kyri_exec_transition_action` |
| N11 | unresolved cannot allocate a fake successful `CRES` | the unresolved path emits `result_recorded: false` and writes nothing; `record_terminal_result` independently refuses a success with no digest |
| N12 | no production mutation from this preparation | aggregates below |

## 7. Operator precheck — required before Stage 3

Three things I cannot read. **Run these and return the output; do not pull,
build, load or retag anything.**

```bash
# 1. The execution image, under the execution identity.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc \
  --format '{{.ID}} {{.Repository}}:{{.Tag}}'
#   require: 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
#            localhost/kyri-capability-execution:g5

# 2. No kyri-CINV-* container may exist. Historical trackb-* stay.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require: NO kyri-CINV-*; trackb-* may remain and must NOT be removed

# 3. Each grant pins the installed entrypoint by digest.
sudo cat /etc/sudoers.d/kyri-exec-launch /etc/sudoers.d/kyri-exec-reconcile
#   require kyri-exec-launch    pins 0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
#                               for /usr/libexec/kyri-exec-transition
#   require kyri-exec-reconcile pins 2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
#                               for /usr/libexec/kyri-exec-reconcile
#   require /etc/sudoers.d/kyri-exec-verify ABSENT
```

## 8. The failure boundary, if Stage 3 is later authorised

If Stage 3 returns `status: unresolved`, the operator must **STOP** and must not
re-run `execute`, must not `podman stop/kill/rm`, must not synthesize a `CRES`,
and must not touch the lifecycle files.

**And per §4, the governed recovery path will not find `CINV-000002` on its
own.** `capability recover` enumerates and cannot be given an identity. Until the
key is corrected, an unresolved `CINV-000002` would be recoverable only after a
source fix — which is the substance of the recommendation to correct §4 first.

## 9. Validation

No source, test or provisioning file changed; this checkpoint adds this report
only.

```
FOCUSED EXECUTE / SUPERVISION / RECOVERY SUITES
  lifecycle 45   protocol 34   cleanup 24   collector 35   result-contract 12
  contract-outcome 25   container-identity 14   reconciliation   supervised-e2e
  capacity 31    quarantine 21  capability-runtime 1089   admin 34
  supervision 32     recovery-discovery 10 (ok-style)          0 FAIL

LOCAL_QUICK   PASS       LOCAL_FULL   PASS       GITHUB CI  6/6      CLEAN CLONE  PASS

CINV-000002  923ff0d7…  unchanged      CINV-000001  1dcef40d…  unchanged
invocation seq 2   CRES 0   handoff unchanged   payload e12a525c… unchanged
fabric 3fa32b83…   trust 53605e4e…              both byte-identical

NO EXECUTION. NO CRES. NO HANDOFF CHANGE. NO LIFECYCLE WRITE.
```

## 10. STOP

```
STAGE3_PREPARED  YES        STAGE3_AUTHORISED  NO
PRODUCTION_INVOKE_AUTHORISED  NO       CINV_000001_RESUME_AUTHORISED  NO
RECOVERY_DISCOVERY_FIX  FAIL
```

Stage 2 is accepted on its own evidence. **Stage 3 should not be authorised until
the recovery-discovery key is corrected**, because the one thing that makes a
failed Stage 3 survivable — the governed recovery path finding the invocation —
is exactly what does not work. That correction is a source change with a RED-first
test, and it belongs in its own checkpoint before the second production
execution, not folded into this one.

If the reviewer decides to proceed regardless, the Stage-3 command in §5 is exact
and the §7 precheck must be returned first.
