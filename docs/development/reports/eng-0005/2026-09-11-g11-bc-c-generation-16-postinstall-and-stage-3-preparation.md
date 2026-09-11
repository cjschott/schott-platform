# ENG-0005 G11-BC-C — Generation-16 post-install verification, and Stage-3 preparation

**Status: Generation 16 is installed and verified. CINV-000002 survived the
generation transition intact. The recovery-discovery fix is LIVE and proven
against the installed runtime. Stage 3 is prepared and NOT authorised.**

The blast radius of Generation 16 is exactly one file, measured rather than
asserted: the installed library differs from the Generation-15 authority in
`recovery.py` and in nothing else.

```
HOST_GENERATION             16        GEN16_VERIFY_INSTALLED   PASS
RECOVERY_DISCOVERY_INSTALLED PASS     EXECUTION_SAFETY_INSTALLED PASS
CINV_000002_SHA256          923ff0d7…  unchanged, launch_authorized
HANDOFF/PROFILE/COMMITMENT  PASS / PASS / PASS
HELPER_COMPATIBILITY        compatible  BLOCKING 0  SUPERVISION_READY true
STAGE3_PREPARED             YES       STAGE3_AUTHORISED        NO
```

**One correction to the expected Stage-3 output carried into this checkpoint.**
The brief anticipated `status=terminal`. The installed runtime emits
`status="prepared"` — `record_terminal_result` returns
`InvocationDecision(STATUS_PREPARED, …)` and `command_execute` emits
`terminal.status` verbatim. An operator comparing against `terminal` would read a
correct success as a failure. §7 carries the derived shape.

Branch `arch/eng-0005-execution-transition`. No execution, no recovery against
production, no reconciler invoked against production, no container, no mutation
of any kind.

---

## 1. Post-install production state

### 1.1 Generation 16 is installed

```
/usr/lib/kyri/python/tools/capability/execution/recovery.py
  fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0   REQUIRED VALUE
/usr/lib/kyri/python/tools/capability/cli.py
  7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1   CARRYOVER, unchanged

library object count  81   unchanged (80 governed + 1 G11-AX helper CREATE)
```

### 1.2 The blast radius, measured

Not taken from the ceremony's report. The installed tree was compared, object by
object, against **both** authorities:

```
vs the Generation-16 authority 91cb1b6 : 74 tools objects, 0 mismatches
vs the Generation-15 authority ef4f744 : exactly 1 object differs —
    tools/capability/execution/recovery.py
      gen15 = f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03
      now   = fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0
```

**One object moved, and it is the declared one.** No CREATE, no removal, group R
coherent — cli.py sits at the carryover digest on both sides.

The flattened privileged modules are untouched and still at their accepted
ceremony targets:

```
kyri_exec_transition_action.py  b11a2f19…   kyri_exec_quota.py       54a9b15c…
kyri_exec_verify.py             f49c2957…   kyri_exec_reconcile.py   29175d5a…
kyri_exec_transition.py         de264c64…   kyri_exec_launcher.py    78c6de90…
kyri_exec_podman.py             cf26b298…
```

### 1.3 Elevation surface unchanged

```
/usr/libexec/kyri-exec-transition  0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1  MATCH
/usr/libexec/kyri-exec-reconcile   2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77  MATCH

/etc/sudoers.d/  kyri-exec-launch  kyri-exec-reconcile  README
                 kyri-exec-verify  ABSENT
```

Both grants `-r--r----- root:root`, mtime 2026-09-04 — untouched by the ceremony.

### 1.4 Readiness, read from the installed runtime

```json
{
  "coordinator_identity_authority": true,
  "execution_identity_authority": true,
  "execution_identity_account": "kyri-capability",
  "helper_compatibility": "compatible",
  "helpers_blocking": [],
  "launch_grant": "unobservable",
  "reconcile_grant": "unobservable",
  "supervision_ready": true
}
```

```
HELPER_COMPATIBILITY  compatible     HELPER_BLOCKING  0     of 8 required helpers
SUPERVISION_READY     true
```

**This is the predicted outcome, not a surprise.** G11-BC-B §5.6 stated that
Generation 16 moves nothing the readiness gate reads, so compatibility would be
unchanged across the transaction — unlike Generation 15, which deliberately drove
it to `incompatible`. It is `compatible` on both sides.

The two grant fields remain `unobservable` by design: the coordinator may not
read the elevation namespace. §5 carries the operator check for them.

## 2. CINV-000002 continuity across the generation transition

```
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa   UNCHANGED
CINV-000001  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
INVOCATION_SEQ 2     CINV_COUNT 2     CRES_COUNT 0     CRES_NEXT CRES-000001
validate_store  status=reported  findings=()
```

**Lifecycle journal, read from disk:**

```
CINV-000002.000001  {"previous":null,      "sequence":1, "state":"reserved"}
CINV-000002.000002  {"previous":"reserved","sequence":2, "state":"launch_authorized"}
```

`LIFECYCLE_STATE = launch_authorized`. No `authorise_launch` was run; the journal
is exactly the two records Stage 2 wrote.

**The launch authorisation still binds what was reviewed:**

```json
{"cimp":"CIMP-000001","cinv":"CINV-000002",
 "commitment_digest":"58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da",
 "handoff_root":"/data/kyri/capability-handoff",
 "lifecycle_state":"launch_authorized",
 "profile_digest":"b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923",
 "profile_schema_version":1}
```

### 2.1 Re-verified with the INSTALLED Generation-16 runtime

Not re-read from the previous report. Every check below imported from
`/usr/lib/kyri/python`.

**Handoff mode matrix** — paths derived from the installed module's own
constants (`PACKAGE_DIRECTORY`, `PAYLOAD_NAME`, `PROFILE_NAME`,
`OUTPUT_DIRECTORY`) and modes from `handoff.HANDOFF_MODES`:

| path | mode | expected | owner | |
| --- | --- | --- | --- | --- |
| `.` | `0555` | `0555` | 1000:1000 | OK |
| `./package` | `0555` | `0555` | 1000:1000 | OK |
| `./package/main.py` | `0444` | `0444` | 1000:1000 | OK |
| `./payload` | `0444` | `0444` | 1000:1000 | OK |
| `./profile` | `0444` | `0444` | 1000:1000 | OK |
| `./out` | `0700` | `0700` | 1000:1000 | OK |

```
MODE_MATRIX PASS     members exactly {out, package, payload, profile} — no extra
```

**Payload** — the handoff carries the canonical bytes:

```
published  254 bytes  e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c
record payload_digest sha256:e2914a90…                                     MATCH
package/main.py       683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd
```

**Profile** — re-parsed from the published bytes with the installed
`parse_canonical_profile`, round-tripped through `canonical_profile` to
**byte-identical** output, and re-fingerprinted:

```
re-derived profile_digest  b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923  MATCH
cinv CINV-000002   cimp CIMP-000001   adapter python-podman-v1
oci_image_id 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

**Commitment** — re-derived by calling the installed `commitment_digest()` on the
record's own `binding_digest`:

```
binding_digest     sha256:58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da
commitment_digest        58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da  MATCH
```

```
HANDOFF_VERIFICATION PASS   PROFILE_VERIFICATION PASS   COMMITMENT_VERIFICATION PASS
```

### 2.2 Stage 3's own first step, run read-only

`supervised_binding("CINV-000002")` is what `command_execute` calls before
anything privileged happens, and it only reads. Run against production with the
installed runtime:

```
cinv            CINV-000002
profile_digest  b707d4334a29fbf9e3e4dfad95897a634f38c8002f711e8bc3a3a0d325941923
profile.cinv    CINV-000002     profile.cimp  CIMP-000001
adapter         python-podman-v1
oci_image_id    5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

It returned rather than raising `LaunchRefused`, which is itself the proof that
the published profile still hashes to the digest the launch authorisation
committed to. **Stage 3's binding step will succeed.**

## 3. The Generation-16 recovery fix is LIVE

Proved against `/usr/lib/kyri/python`, not repository source.

### 3.1 The installed function

```python
# /usr/lib/kyri/python/tools/capability/execution/recovery.py
return record.get("invocation_record_id") or record.get("invocation_id")
```

```
keys by invocation_record_id FIRST : True
G11-BB-Z defect ordering present   : False
```

### 3.2 Against the real production records, read-only

`unresolved_invocations` performs no write and calls no reconciler. **No
governed recovery was run and `execution_safety` was NOT invoked against
production.**

```
lifecycle journal keys : CINV-000001 -> launch_authorized
                         CINV-000002 -> launch_authorized

CINV-000001  invocation_id (opaque)  'g11bb-first-controlled-invoke'
             _invocation_identity()  'CINV-000001'      differs from opaque: True
             states.get(identity)    LAUNCH_AUTHORIZED
             states.get(opaque)      None               <- the G11-BB-Z miss

CINV-000002  invocation_id (opaque)  'g11bb2-second-controlled-invoke'
             _invocation_identity()  'CINV-000002'      differs from opaque: True
             states.get(identity)    LAUNCH_AUTHORIZED
             states.get(opaque)      None               <- the G11-BB-Z miss

unresolved_invocations(...)  ->  2 discovered
  CINV-000001  carried_identity=CINV-000001  adapter=None  lifecycle=launch_authorized
  CINV-000002  carried_identity=CINV-000002  adapter=None  lifecycle=launch_authorized
  both carried identities are canonical CINVs : True
```

Before Generation 16 this returned `()`. **Both production invocations are now
discoverable, at their real lifecycle state, carrying the canonical CINV.**

```
RECOVERY_DISCOVERY_INSTALLED = PASS
```

### 3.3 execution_safety is no longer vacuous — fixture only

`execution_safety` invokes the reconciler, so it was **not** run against
production. It was driven against a temporary fixture using the installed
runtime, with the production record shape — an opaque `invocation_id` that
differs from the CINV:

```
fixture: invocation_record_id=CINV-000044  invocation_id='g11bcc-opaque-invoke'

A  discovered                       ['CINV-000044'] at launch_authorized
B  reconciler asked about           ['CINV-000044']   <- the canonical CINV
C  REFUSING reconciler              not-ready  checked=1  blocking=['CINV-000044']
D  PROVING reconciler               ready      checked=1  blocking=[]
D2 container ALREADY absent         ready      checked=1
E  CONTROL, empty store             ready      checked=0
F  UNREADABLE report                not-ready  checked=1
     reason: "the reconciliation report is unreadable"

ready-because-checked vs ready-because-nothing-looked-at: distinguishable (1 vs 0)
```

**Case F is the one that matters most** and it was not in the original battery: a
reconciler returning something that is not a dict is treated as *unresolved*, not
as a pass. The gate fails closed on an unreadable answer.

```
EXECUTION_SAFETY_INSTALLED = PASS
```

**A wrong fixture of mine, corrected by the run.** My first proving-reconciler
stub returned an object with a `final_absent` attribute and case D came back
`not-ready`. The installed code requires a **dict** —
`isinstance(report, dict) and report.get("final_absent") is True` — so the stub,
not the runtime, was wrong. Reporting D as a failure would have been a false
alarm about a correctly installed generation. The corrected fixture uses the real
contract, and D passes.

## 4. The expired Fabric lease, re-traced on installed Generation 16

```
FABRIC_LEASE_EXPIRED                                  YES
STAGE1_DECISION_WAS_IN_WINDOW                         YES
STAGE3_REVALIDATES_FABRIC                             NO
EXPIRED_LEASE_BLOCKS_EXISTING_LAUNCH_AUTHORIZED_CINV  NO
```

### 4.1 Could Generation 16 have changed this? No — measured

Generation 16 moved exactly one object (§1.2), and that object contains **zero**
references to Fabric, CSEL, CINST, CADV, `admitted_until`, eligibility or
`verify_selected_evidence`:

```
grep -c -iE "fabric|CSEL|CINST|CADV|admitted_until|eligib|verify_selected"
  /usr/lib/kyri/python/tools/capability/execution/recovery.py  ->  0
```

### 4.2 The complete reachability chain, on the installed tree

`admitted_until` is read at exactly two sites, and both funnel into one entry
point:

```
fabric_evidence.py:267  _text(instance,"admitted_until")   inside _window_open (:264)
  _window_open  <- fabric_evidence.py:335, inside verify_selected_evidence (:282)

fabric/eligibility.py:573  _instant(instance["admitted_until"])  inside _admitted (:558)
  _admitted  <- evaluate_eligibility (:405)
  evaluate_eligibility  <- fabric_evidence.py:459, inside verify_selected_evidence (:282)
```

And `verify_selected_evidence` has exactly two callers:

```
coordinator.py:110   inside prepare_invocation   <- STAGE 1
cli.py:396           inside command_preflight    <- a Stage-1 rehearsal
```

**Neither is Stage 3.**

### 4.3 Stage 3 has no path to the Fabric store at all

```
command_execute body: no fabric / eligibility / CSEL / CINST / CADV /
  verify_selected_evidence / store-root reference
  (the only hit is one docstring sentence: "invoke verified eligibility")

execute subparser, installed:
  --expected-uid  --expected-gid  --cinv  --actor  --recorded-at
  NO --fabric-store-root, NO --trust-store-root
```

The privileged side is clean too. Across `supervision.py`, `launch.py`,
`profile.py`, `worker.py`, `kyri_exec_launcher.py`, `kyri_exec_transition.py`,
`kyri_exec_transition_action.py`, `kyri_exec_reconcile.py`, `kyri_exec_podman.py`
and `/usr/libexec/kyri-exec-worker.py`, the only match is a **docstring** in
`launch.py:27`:

> *"It re-runs no governed decision it does not own. Fabric selection and package
> resolution happened at preparation and are read back from the durable
> invocation record; Trust is not consulted at all."*

### 4.4 Why expiry cannot change a verdict already reached

```python
def _window_open(instance, instant):
    """The admission window, as recorded, containing the supplied instant."""
    return start <= instant < end
```

The instant is **supplied**. And on the installed Generation-16 runtime:

```
grep -rn "datetime.now|utcnow|time.time()|date.today"
  /usr/lib/kyri/python/tools/capability/   ->   NONE
```

**There is no wall-clock call anywhere in the installed capability runtime.**
Every instant is operator-supplied (`--requested-at`, `--recorded-at`).

```
CINST-000004  admitted_at 2026-09-07T14:15:00-05:00
              admitted_until 2026-09-10T21:30:00-05:00   <- expired
CINV-000002   requested_at 2026-09-09 11:50:22-05:00     <- inside the window
```

Expiry is therefore not a state the runtime can drift into. It changes exactly
one thing: a **new** invocation prepared against CINST-000004 today would supply
a current instant, fail `_window_open`, and be refused with `REASON_WINDOW`. That
is correct and unchanged. The lease bounds when a decision may be *made*; Stage 3
makes none, and asks none.

## 5. Pre-Stage-3 operator observation — read-only, required

Three things the coordinator cannot see: `/data/kyri/capability` is
`drwxr-x--- kyri-capability`, and the grant files are `root:root 0440`. **Run
these immediately before any Stage-3 authorisation and return the output. Do not
pull, build, load, retag, stop, kill or remove anything.**

```bash
# 1. The execution image, under the execution identity.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc \
  --format '{{.ID}} {{.Repository}}:{{.Tag}}'
#   require: 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
#            localhost/kyri-capability-execution:g5

# 2. No kyri-CINV-* container may exist. The seven historical trackb-* stay.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require: NO kyri-CINV-*; trackb-* may remain and must NOT be removed

# 3. Each grant pins the installed entrypoint by digest.
sudo cat /etc/sudoers.d/kyri-exec-launch /etc/sudoers.d/kyri-exec-reconcile
#   require kyri-exec-launch    pins 0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
#                               for /usr/libexec/kyri-exec-transition
#   require kyri-exec-reconcile pins 2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
#                               for /usr/libexec/kyri-exec-reconcile

# 4. The verification grant is still absent.
sudo test ! -e /etc/sudoers.d/kyri-exec-verify && echo "verify grant ABSENT (required)"

# 5. sudoers parses cleanly.
sudo visudo -c
#   require: /etc/sudoers: parsed OK, and every /etc/sudoers.d file parsed OK
```

The coordinator-side `execution_image_available` field is **not** authoritative
for check 1 (G11-BB-X §3.2). Observe the execution identity's own Podman store.

## 6. The Stage-3 command, derived from installed Generation-16 source

The parser was read out of `/usr/lib/kyri/python/tools/capability/cli.py`: five
required arguments, no roots, no adapter, no image, no argv.

```bash
# STAGE 3 -- NOT AUTHORISED. Crosses the privileged boundary and writes CRES-000001.
cd /opt/schott-platform
python3 -m tools.capability.cli execute \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000002 \
  --actor primary-platform-operator \
  --recorded-at "$(date -Is)" ; echo "rc=$?"
```

That the caller supplies no adapter, backend, binding, image or argv is a
property of the surface, not a convention: there is no flag for any of them.

## 7. Expected terminal success, derived from installed source

`command_execute` emits exactly these nine keys on the success path:

```
cinv                       CINV-000002
status                     "prepared"     <- see below
reason                     terminal.reason  (None on an admitted success)
invocation_record_id       CINV-000002
result_record_id           CRES-000001
succeeded                  true
result_digest              non-null       (a success with no digest is refused)
result_artifact_reference  null           (command_execute passes None)
disposal_proven            true           (a literal on the success path)

EXPECTED_STAGE3_RC  0     (EXIT_SUCCESS = 0, returned when terminal.succeeded)
```

### 7.1 `status` is `"prepared"`, not `"terminal"`

The brief anticipated `status=terminal`. The installed source does not produce
that value anywhere:

```python
# evidence.py, end of record_terminal_result
return InvocationDecision(
    STATUS_PREPARED, reason, invocation_record_id=invocation_record_id,
    result_record_id=identity, succeeded=admitted, ...)

# evidence.py:48
STATUS_PREPARED = "prepared"

# cli.py command_execute
"status": terminal.status,
```

```
STATUS_PREPARED = 'prepared'
```

**An operator checking for `terminal` would read a correct success as a failure.**
The discriminator between the two outcomes is not this field's *value* so much as
which field set is present — and `rc` alone is ambiguous, because Stage 1 also
returns 1 on success. §7.3 is the reliable test.

### 7.2 Why `CRES-000001`

Derived from the installed allocator, not assumed:

```
id_prefixes            {'capability-invocation': 'CINV', 'capability-result': 'CRES'}
width                  6
sequences/capability-result.seq   ABSENT  -> raw="" -> current=0 -> candidate=1
capability-results/               EMPTY   -> no collision
existing results       []
                                            => CRES-000001
```

### 7.3 Fields that exist ONLY on the unresolved path

If supervision is refused, `command_execute` emits a **different object** and
`result_recorded` is `false` — **no `CRES` is written**:

```
status            "unresolved"   <- literal
reason            str(refusal)
protocol_states   list           ONLY here
worker_reaped     bool | null    ONLY here
reconciled        value | null   ONLY here
result_recorded   false          ONLY here
disposal_proven   present on both, but false-able only here
rc                1 (EXIT_DENIED)
```

**These must NOT be required on success.** `protocol_states`, `worker_reaped`,
`reconciled` and `result_recorded` do not appear on the success path at all.
Conversely `invocation_record_id`, `result_record_id`, `succeeded`,
`result_digest` and `result_artifact_reference` do not appear on the unresolved
path.

**Read `status`, and read which keys are present. Do not read `rc` alone.**

## 8. The failure boundary, and what is different now

If Stage 3 returns `status: "unresolved"`, the operator must **STOP** and must
not re-run `execute`, must not `podman stop/kill/rm`, must not synthesize a
`CRES`, and must not touch the lifecycle files. Only governed recovery may then
be considered, under its own authorisation.

**What Generation 16 changed about that boundary.** G11-BB-Z §8 had to warn that
*"the governed recovery path will not find CINV-000002 on its own"* — `capability
recover` enumerates and cannot be handed an identity, and the enumeration was
blind. §3.2 proves that is no longer true: run against the real store,
`unresolved_invocations` discovers `CINV-000002` today, at `launch_authorized`,
carrying the canonical CINV that `launcher.reconcile` validates and the sudo
grant pins.

So an unresolved Stage 3 is now **recoverable by the governed path** rather than
requiring a source fix first. That was the entire reason Stage 3 was blocked at
G11-BB-Z, and it is the reason the block can now lift.

`capability recover` remains a **privileged action needing its own
authorisation**. It is not authorised here, and it would act on `CINV-000001`
too — which stays permanently historical UNRESOLVED and must not be resumed.

## 9. The result contract

A successful Stage 3 writes `CRES-000001` with:

```
invocation_record_id       CINV-000002
succeeded                  true
result_digest              non-null
result_artifact_reference  null
attempt_number             1
outcome_class              one of records.OUTCOME_CLASSES
```

```
RESULT_FIELDS = (capability_result_id, invocation_record_id, attempt_number,
                 outcome_class, reason, result_digest, result_artifact_reference,
                 started_at, ended_at, recorded_at, kind, schema_version, evidence)

'selection_id'  in RESULT_FIELDS : False
'instance_id'   in RESULT_FIELDS : False
'invocation_id' in RESULT_FIELDS : False
```

**Confirmed: the `CRES` carries neither `selection_id` nor `instance_id`, and
that is correct.** They bind transitively through `invocation_record_id` →
`CINV-000002` → `CSEL-000003` / `CINST-000004`, and the record read back from the
store carries exactly those:

```
CINV-000002  selection_id CSEL-000003   instance_id CINST-000004   operation execute
```

The schema is closed, so adding them would be refused as unknown fields.

`record_terminal_result` **never touches the invocation record** — *"CINV is the
immutable pre-execution attempt evidence … Recording completion by editing it
would destroy the property that makes it worth having."* So `CINV-000002`'s
digest must be `923ff0d7…` after Stage 3 as well. It also refuses an
undescribable pair — a success with no digest, or a failure carrying one — so a
fabricated success cannot be written.

## 10. Validation

```
FOCUSED SUITES
  recovery-discovery   all assertions hold      supervision       PASS
  reconciliation       PASS (real containers)   lifecycle         PASS
  contract-outcome     PASS
  generation-16 installer PASS                  generation succession PASS
  g5 preflight         PASS

LOCAL_QUICK  PASS  110/110 steps
LOCAL_FULL   PASS  135/135 steps
GITHUB_CI    see §10.3
CLEAN_CLONE  n/a — the only repository changes are this report and five
             test-suite successor lists; no ceremony, installer or runtime
             object moved
```

The Generation-16 installer suite still passes **against a host that is now at
Generation 16**. That is the succession discipline working: the suite
reconstructs its Generation-15 baseline from the live path set plus reviewed git
bytes, so it does not silently start reconstructing whatever the host happens to
hold.

### 10.1 The installation broke a host-only suite — the known class, for the third time

Full validation stopped at step 107:

```
FAIL: the live host is wholly at one of the two declared generations -- raised:
AssertionError: ('objects in neither declared state',
  [('tools/capability/execution/recovery.py', 'fdad3cec…')])

Generation-13 packaging validation FAILED: 1
Validation stopped at step 107. Nothing after it ran.
```

**This is a stale test fixture, not a production problem.** `recovery.py` is a
Generation-13 `CREATE` row (`ABSENT → a93819d1`) and a Generation-15 `REPLACE`
row (`a93819d1 → f44ada7f`). `test-capability-execution-generation13-packaging.sh`
asks whether every Generation-13 row is at its baseline, its target, or a state a
**later** generation superseded it into — reading the successor matrices from a
named list. That list stopped at Generation 15, so the installed `fdad3cec…` was
in none of the three and a correctly installed host was reported as drift.

`tests/lib/succession.sh` exists for exactly this and names two prior
occurrences: *"Generation 13 broke three suites when it landed, and the
Generation-15 installation broke six."* The failing function's own comment
records the second one. **This is the third.**

Fixed by naming the ceremony, which is what the design intends — the list is the
suite's declaration of which successors it accounts for:

```python
for name in ('install-generation-14.sh', 'install-generation-15.sh',
             'install-generation-16.sh'):
```

### 10.2 The sweep the failure justified, and what it found

Validation fail-fasts, so everything after step 107 had not run. Rather than fix
one suite and re-run hopefully, every suite that enumerates successor ceremonies
was inspected.

**Five more lists were incomplete, and all five passed only by coincidence.**
Generation 16 moves `recovery.py`, and `recovery.py` also happens to be a
Generation-15 row — so every fixture that already rewound through Generation 15
restored it as a side effect:

```
Gen15 rows (rewound)     helpers.py, kyri-exec-launcher.py, verification.py,
                         result_content.py, contract_outcome.py, recovery.py, cli.py
Gen16 rows (NOT rewound) recovery.py                     <- covered only by overlap
```

Had Generation 16 touched an object Generation 15 did not, those fixtures would
have **silently carried Generation-16 bytes while asserting they were a
Generation-13 or Generation-14 host** — a wrong fixture that passes, which is
worse than the loud failure above. The lists are now complete:

| suite | list | effect today |
| --- | --- | --- |
| `generation13-packaging` | `superseded_by_successor()` | **required** — this is the failure |
| `generation13-packaging` | `helper_creates()` | no-op (Gen16 CREATEs nothing) |
| `generation13-packaging` | fixture `succession_created_by` | no-op |
| `generation13-installer` | fixture `succession_created_by` | no-op |
| `generation12-packaging` | `creates` | no-op |
| `generation14-installer` | `succession_rewind` | no-op today, **removes the coincidence** |
| `helper-ceremony` | `succession_rewind` | no-op today, **removes the coincidence** |

All five suites pass after the change, and so do `generation12-packaging` and
`generation13-packaging`:

```
generation12-packaging  PASS    generation13-packaging  PASS
generation13-installer  PASS    generation14-installer  PASS
helper-ceremony         PASS    shellcheck              rc=0
```

Nothing was suppressed, no assertion was weakened, and no expectation was
re-pointed at whatever the host now holds — which the helper-ceremony suite's own
comment warns is the tempting wrong fix: *"bumping the constant to whatever the
host now holds would make the assertion below vacuous."*

## 11. Production remains unexecuted

```
host generation              16
installed recovery.py        fdad3cec…        the correction, live
installed cli.py             7b4fac3e…        carryover, unchanged
CINV-000002                  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
CINV-000002 lifecycle        launch_authorized
invocation sequence          2       CINV count 2
CRES count                   0       CRES-000001 unspent
handoff                      unchanged, mode matrix PASS
Fabric / Trust               not read for mutation, not written
sudoers                      two grants, verify grant absent, unchanged
```

```
NO EXECUTION. NO RECOVERY AGAINST PRODUCTION. NO RECONCILER INVOKED AGAINST
PRODUCTION. NO CRES. NO CONTAINER. NO LIFECYCLE WRITE. NO HANDOFF CHANGE.
NO FABRIC WRITE. NO TRUST WRITE. NO SUDOERS EDIT.
```

`execution_safety` was exercised only against a temporary fixture, torn down when
the check finished. The read-only enumeration that ran against production calls
no reconciler and performs no write.

## 12. STOP — the reviewer and operator gate

```
STAGE3_PREPARED  YES        STAGE3_AUTHORISED  NO
PRODUCTION_INVOKE_AUTHORISED  NO       CINV_000001_RESUME_AUTHORISED  NO
```

Everything that blocked Stage 3 at G11-BB-Z is now resolved: the recovery
discovery key is corrected and **deployed**, the fix is proven live against the
real records, CINV-000002 came through the generation transition untouched, and
the expired Fabric lease is proven not to re-open.

The next step is **reviewer acceptance of this post-install continuity and
Stage-3 preparation, then the operator runs the §5 read-only block and returns
its output** — before any execute authorisation is considered.
