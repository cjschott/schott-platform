# ENG-0005 G11-BC-G — the deployment is correct; its evidence is not

**Status: STOPPED. Generation 17 and the corrected helper are installed and
every installed byte is provably right. But the helper ceremony wrote its
evidence over G11-BB's, under G11-BB's name, claiming Generation 14 — so §8's
gate is met twice and resume is not authorised.**

```
RESULT                          STOPPED
HOST_GENERATION                 17
HELPER_COMPATIBILITY            compatible   BLOCKING 0   SUPERVISION_READY true
all four deployment digests     exactly as reviewed

HELPER_EVIDENCE_PATH_POLICY     DEFECTIVE — wrote to the G11-BB pathname
HISTORICAL_EVIDENCE_DESTROYED   YES (artifact; information reconstructible)
CURRENT_HELPER_EVIDENCE_VALID   NO — misidentifies its ceremony and generation

CINV_000002_RESUME_POSSIBLE     YES        RECOVERY_REQUIRED_BEFORE_RESUME  NO
CINV_000002_RESUME_AUTHORISED   NO
```

**The deployment itself is not in question.** I verified every installed digest
directly against the reviewed commit, without reading the evidence file at all —
which is also why the evidence defect does not make the host unsafe. What it
destroys is the audit trail, and §8 says stop for that.

Branch `arch/eng-0005-execution-transition`. No execution, no recovery, no
mutation of production state.

---

## 1. The installed state, accepted

```
tools/capability/execution/helpers.py
  78da8519db99fa06e809755808397fe36bb8c83872deab142987c98308b38a4f   MATCH
kyri_exec_launcher.py
  152038b198c112c3f5f042114eb6e7f4ffa3a9caeb431908bfe7f208b136447d   MATCH
kyri_exec_podman.py
  04205c53ec0e10bef13099dd3a84c483e43ed9441335805665f957a5bbdd896b   MATCH
kyri_exec_transition_action.py
  d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de
```

The action digest was **derived, not assumed**: the blob at the reviewed commit
`15a8c738f97394a4f114070c011db22562466ed6` hashes to exactly the installed
value.

```
recovery.py  fdad3cec…   (the Generation-16 correction, still installed)
entrypoints  0d9c8d8c… / 2878fff0…   unchanged, so both grants still pin
sudoers      kyri-exec-launch, kyri-exec-reconcile, README — verify grant ABSENT
Root Authority   no kyri mount

helper_compatibility  compatible    declared 8    blocking 0
supervision_ready     true
coordinator identity  present       execution identity  present (kyri-capability)
```

## 2. CINV-000002, and where the failed attempt lives

```
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
CINV-000001  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
INVOCATION_SEQ 2     CRES_COUNT 0     CRES-000001 unspent     no new CINV
```

**Every durable execution transition for CINV-000002 — the complete set:**

```
CINV-000002.000001  {"previous":null,      "sequence":1, "state":"reserved"}
CINV-000002.000002  {"previous":"reserved","sequence":2, "state":"launch_authorized"}
```

Two records. The execution directory holds one object, the launch
authorisation. `state/` is empty. The CMUT counter is at 6, and all six
mutations are paired intent+outcome from Stage 1 and Stage 2.

### 2.1 The failed Stage 3 is represented durably NOWHERE, and that is the design

```
find /data/kyri/capability-runtime -newermt "2026-09-10 06:00"   ->   nothing
```

**Not one byte of the runtime store has changed since Stage 2 completed at
2026-09-10 05:00.** The Stage-3 attempt on 2026-09-11 wrote no lifecycle record,
no mutation, no result, and no partial artefact.

That is `record_terminal_result`'s contract working: the unresolved path emits
`result_recorded: false` and writes nothing, precisely so a failed attempt
leaves the invocation exactly where it was. The lifecycle still reads
`launch_authorized` because nothing transitioned it, and the CINV is still
`923ff0d7…` because nothing may edit it.

The attempt's only durable representation is the operator's console output and
the G11-BC-D report. **That is why a second `execute` is not a retry over
partial state — there is no partial state.**

## 3. Both corrections, verified from installed bytes

### A. The output-leaf transfer

```
/usr/lib/kyri/python/kyri_exec_transition_action.py

  os.open(policy.cinv, _DIR_FLAGS, dir_fd=root)          descriptor-relative
  os.open(OUTPUT_DIRECTORY_NAME, _DIR_FLAGS, dir_fd=…)   no-follow, O_DIRECTORY
  os.fstat(leaf) -> S_ISDIR, S_IMODE checked BEFORE
  backend.fchown(leaf, policy.worker_uid, policy.worker_gid)
  os.fstat(leaf) -> owner AND mode re-checked AFTER

  OUTPUT_DIRECTORY_MODE = 0o700
  os.fchown sites in the whole installed surface : 1
  path-based chown anywhere                      : NONE
```

Owner target is `policy.worker_uid` / `policy.worker_gid`, which the execution
identity authority resolves to `kyri-capability` **999:987**.

**Ordering, from the installed module:** `perform_transition` calls
`transfer_output_leaf` at line 868 and `drop_privilege` at line 889 — the
transfer happens while root is still held, before the dropped identity ever
needs `out/`.

### B. cwd sanitisation

```
kyri_exec_transition_action.py:736   backend.chdir(policy.working_directory)
kyri_exec_transition.py:65           WORKING_DIRECTORY = "/"
kyri_exec_podman.py                  SAFE_WORKING_DIRECTORY = "/"
  subprocess.run line 275  cwd STATED
  subprocess.run line 430  cwd STATED
  subprocess.run line 510  cwd STATED
```

The drop consumes the **governed** policy value rather than a duplicate
constant, and all three runtime subprocess sites state cwd explicitly. An
inherited caller cwd cannot cross the identity boundary: the chdir precedes the
credential change, so everything beyond `execve` starts at `/`.

## 4. The handoff, before resume

```
CURRENT_OUT_OWNER = cschott:cschott
CURRENT_OUT_MODE  = 700

.          cschott:cschott 555      package/  cschott:cschott 555
payload    cschott:cschott 444      profile   cschott:cschott 444
```

Not modified by this checkpoint, and correctly so.

```
RESUME_TRANSITION_WILL_TRANSFER_OUT_OWNER = YES
```

Proven end-to-end through installed bytes:

```
cli.command_execute
  -> _helper_launcher() -> HelperLauncher.launch(CINV-000002)
  -> sudo /usr/libexec/kyri-exec-transition CINV-000002
  -> /usr/libexec/kyri-exec-transition:125   action.perform_transition(...)
  -> action:868                              transfer_output_leaf(...)   [as root]
  -> action:889                              drop_privilege(...)
```

The mode precondition already holds: the transfer requires `out/` to be `0700`
before it will proceed, and it is.

## 5. Container and image — operator observation required

`/data/kyri/capability` is `drwxr-x--- kyri-capability` and sudo needs a
password in this session.

```
KYRI_CINV_CONTAINER_COUNT  NOT OBSERVABLE (operator check, §9)
EXECUTION_IMAGE_PRESENT    NOT OBSERVABLE (operator check, §9)
```

Not worked around. Both are in the pre-resume block.

## 6. Resume semantics — there is no resume branch, and that is better

```
RESUME_BRANCH    none. `command_execute` contains no lifecycle branch whatsoever.
RESUMED_EXPECTED false
```

The brief asks me to prove that `launch_authorized` "enters the intended resumed
branch". **It does not, because no such branch exists on the execute path**, and
the distinction matters:

- `command_execute` never reads the lifecycle journal. It reads the record,
  builds the binding from the published authorisation, and runs.
- The `resumed` flag belongs to `authorise_launch` and is emitted only by
  `command_authorise_launch` (cli.py:601). A second `execute` never calls it, so
  nothing will report `resumed`.
- The **one** lifecycle gate on the path is inside the privileged policy:

```python
# kyri-exec-transition.py:745
state = record["lifecycle_state"]
_require(isinstance(state, str) and state == LAUNCH_AUTHORIZED,
         "the invocation is not launch_authorized")
```

The published authorisation carries `launch_authorized`, so the privileged
transition authenticates and proceeds. A second `execute` is therefore
**structurally identical to the first**, not a special path — which is exactly
why it is safe.

The rest, proven from installed source:

| claim | proof |
| --- | --- |
| no CINV-000003 | `allocate_id(INVOCATION_KIND)` appears only in `record_invocation` (evidence.py:423), which is Stage 1. Execute reaches `record_terminal_result`, which allocates `RESULT_KIND` only. |
| no second authorise-launch | `supervised_binding` reads the published authorisation back; nothing re-runs the Stage-2 decision |
| CINV not rewritten | `record_terminal_result` never touches the invocation record |
| the existing handoff is used | `supervised_binding` re-hashes the published profile and refuses unless it equals the committed digest |
| corrected transition executes | the launch entrypoint routes to `perform_transition` in the installed d40f5121 module |
| ownership transfer occurs | §4 |
| cwd sanitised | §3B |
| governed image | `profile.oci_image_id` compared against observed; the published profile names `5cee2b53…` |
| reconciliation uses safe cwd | all three Podman sites state `cwd`, and the drop sets it before `execve` |
| result is CRES-000001 | results directory empty, `capability-result.seq` absent → `current=0` → candidate 1 |
| no duplicate result identity | `record_terminal_result` refuses a second `attempt_number == 1` for the same `invocation_record_id`; none exists |

```
CINV_000002_RESUME_POSSIBLE = YES
```

## 7. Recovery is not required first

```
RECOVERY_REQUIRED_BEFORE_RESUME = NO
```

- **Nothing durable was written** by the failed attempt (§2.1), so there is no
  partial state for recovery to resolve.
- The failure was `WorkerRefused` on the handoff `out` check, which happens in
  `verify_handoff` **before** any container is created — the worker never
  reached `create_argv`.
- `worker_reaped: true` was reported, and no `kyri-CINV-*` container exists
  (operator re-confirmation in §9).
- Recovery resolves *containers*, not invocations. With no container, a
  governed recovery would discover CINV-000002 — the installed Generation-16 fix
  makes it discoverable at `launch_authorized`, which is
  `_CONTAINER_POSSIBLE_FROM` — and reconcile it to `final_absent` without
  changing anything.

So recovery is *available* and *unnecessary*. It remains unauthorised.

## 8. THE STOP — the helper ceremony's evidence

The successful ceremony printed:

```
helper ceremony evidence written to /root/kyri-g11-bb-helper-digests.txt
```

That is **G11-BB's** pathname. Three defects, all inherited verbatim when this
ceremony was derived from `install-g11-bb-helpers.sh`:

| # | line | defect |
| --- | --- | --- |
| 1 | `HELPER_EVIDENCE="/root/kyri-g11-bb-helper-digests.txt"` | writes to G11-BB's file, **overwriting it** |
| 2 | `printf 'ceremony g11-bb-helpers\n'` | the content **misidentifies its own ceremony** |
| 3 | `printf 'runtime_generation 14\n'` | claims **Generation 14**; it ran against 17 |

Every other ceremony uses its own namespace — `g11-ax`, `gen5`…`gen17`. Only
this one collided.

**Why the guard did not catch it.** `require_namespace_isolation` compared
`TRANSACTION_ROOT` and nothing else; `HELPER_EVIDENCE` was never checked. It is
the same class as the G11-BC-F reviewed-history defect — a namespaced constant
carried through a derivation — and the **second** field of that kind my BC-E
derivation missed. My namespace sweep at BC-E was incomplete, and this is the
cost.

```
HELPER_EVIDENCE_PATH_POLICY = each ceremony writes its own namespaced evidence
                              file and overwrites no predecessor's. G11-BC-E
                              violated it on all three counts above.
HISTORICAL_EVIDENCE_DESTROYED = YES
CURRENT_HELPER_EVIDENCE_VALID = NO
```

### 8.1 What was destroyed, and what was not

**Destroyed:** the durable artifact recording what the G11-BB ceremony
installed. It was `0400 root` and was replaced by `mv -f`.

**Not destroyed — the information survives in reviewed, durable form:**

- G11-BB's three matrix rows, with predecessor and target digests, at its
  reviewed commit in git
- the installed digests themselves, still observable and byte-identical to
  G11-BB's targets (`kyri_exec_quota.py` `54a9b15c…`,
  `/usr/libexec/kyri-exec-worker.py` `2d320630…`)
- the G11-BB-R acceptance report

So the record is **reconstructible**, but it is not currently *recorded*.

### 8.2 Nothing reads it, which is why the deployment is still sound

No ceremony reads `HELPER_EVIDENCE` in any mode — `--verify-installed` never
references it. The only readers are the AX suite against its own fixture copy.
The installed state is therefore verifiable without it, which is exactly how §1
verified it.

**This is an audit and records defect, not a correctness defect.** I am stopping
because §8 instructs it and because a deployment whose own evidence names the
wrong ceremony and the wrong generation cannot be attested from its artifacts —
not because the host is wrong.

### 8.3 What this checkpoint changed, and what it did not

Corrected in **source**, so the shipped ceremony is right and the class cannot
recur:

```
HELPER_EVIDENCE  -> /root/kyri-g11-bc-e-helper-digests.txt
content          -> ceremony g11-bc-e-helpers, runtime_generation 17
require_namespace_isolation now also refuses an evidence path belonging to the
  g11-ax or g11-bb ceremony, and requires this ceremony's own namespace
```

**No evidence file was rewritten**, per the instruction. `/root` was not touched
and nothing was deleted.

Note that re-running the ceremony will **not** regenerate evidence: `--install`
exits early with *"the helper set is already installed: nothing to do"* before
reaching the evidence writer. Remediation therefore needs a deliberate operator
decision, proposed in §12 — it is not something a re-run fixes.

### 8.4 A second defect the deployment exposed: two suites were judging production

Full validation then failed the Generation-16 installer suite at eleven
assertions, all of the form *"a failure at 'X' left helper compatibility
reporting incompatible"*.

**The cause is not the fixture.** `REQUIRED_HELPERS` carries compiled-in
ABSOLUTE paths, so `helpers.compatibility()` judges the **live host** regardless
of which tree the module was imported from. The Generation-16 and Generation-17
suites both called it bare, so their readiness assertions were silently about
production — true only while the live helper surface still matched that
generation's declaration, and inverted the moment the G11-BC-E ceremony moved
the action module.

That is the same family as everything else this sequence has surfaced: a check
that appears to be about a fixture but actually reads the host, so it holds by
coincidence until the host moves.

Fixed by rebasing the declared paths onto the fixture root and passing them in —
`compatibility()` accepts `required=` for exactly this purpose — so the
assertion now asks what it always claimed to ask: *what does THIS FIXTURE
report*. Both suites pass, and neither depends on the live helper surface any
more.

## 9. Pre-resume operator check — read-only, required

```bash
# ---- G11-BC-G pre-resume verification. READ-ONLY. Run immediately before any
# ---- resume authorisation and return the complete output.
set -Eeuo pipefail
cd /opt/schott-platform

echo "== invocation anchor =="
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000002.yaml
#   require 923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
cat /data/kyri/capability-runtime/execution/transitions/CINV-000002.000002
#   require "state":"launch_authorized"
cat /data/kyri/capability-runtime/sequences/capability-invocation.seq        # require 2
ls /data/kyri/capability-runtime/capability-results/ | wc -l                 # require 0

echo "== installed runtime and helper =="
sha256sum /usr/lib/kyri/python/tools/capability/execution/helpers.py \
          /usr/lib/kyri/python/kyri_exec_launcher.py \
          /usr/lib/kyri/python/kyri_exec_podman.py \
          /usr/lib/kyri/python/kyri_exec_transition_action.py
#   require 78da8519… / 152038b1… / 04205c53… / d40f5121…

echo "== readiness =="
python3 -c "
import sys; sys.path.insert(0,'/usr/lib/kyri/python')
from tools.capability.execution import helpers
from tools.capability.cli import _supervision_outlook
c=helpers.compatibility()
print('compatibility', c.verdict, 'blocking', len(c.blocking))
print('supervision_ready', _supervision_outlook()['supervision_ready'])"
#   require: compatible 0 / True

echo "== handoff, observed not altered =="
stat -c '%U:%G %a %n' /data/kyri/capability-handoff/CINV-000002/out
#   expect cschott:cschott 700 -- the privileged transition transfers it

echo "== execution image, under the execution identity =="
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc \
  --format '{{.ID}} {{.Repository}}:{{.Tag}}'
#   require 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
#           localhost/kyri-capability-execution:g5

echo "== no governed container may exist =="
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require NO kyri-CINV-*; historical trackb-* may remain and must NOT be removed

echo "== grants =="
sudo cat /etc/sudoers.d/kyri-exec-launch /etc/sudoers.d/kyri-exec-reconcile
#   require kyri-exec-launch    pins 0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
#           kyri-exec-reconcile pins 2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
sudo test ! -e /etc/sudoers.d/kyri-exec-verify && echo "verify grant ABSENT (required)"
sudo visudo -c
```

## 10. The resume command, derived from installed Generation-17 source

The parser was read out of `/usr/lib/kyri/python/tools/capability/cli.py`. It is
unchanged from the Stage-3 command — five required arguments, no roots — and
that was verified rather than assumed:

```bash
# NOT AUTHORISED. Crosses the privileged boundary and writes CRES-000001.
cd /opt/schott-platform
python3 -m tools.capability.cli execute \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000002 \
  --actor primary-platform-operator \
  --recorded-at "$(date -Is)" ; echo "rc=$?"
```

## 11. Expected success, re-derived

`command_execute` emits exactly nine keys on the success path:

```
cinv                       CINV-000002
status                     "prepared"        <- NOT "terminal"
reason                     terminal.reason   (None on an admitted success)
invocation_record_id       CINV-000002
result_record_id           CRES-000001
succeeded                  true
result_digest              non-null
result_artifact_reference  null
disposal_proven            true

EXPECTED_STAGE3_RC  0
```

`status` is `"prepared"` because `record_terminal_result` returns
`InvocationDecision(STATUS_PREPARED, …)` and `STATUS_PREPARED = "prepared"`.
Checking for `terminal` would read a correct success as a failure.

**The unresolved key set that requires STOP** — these appear on the failure path
and nowhere else:

```
status            "unresolved"    <- literal
protocol_states   list            ONLY here
worker_reaped     bool | null     ONLY here
reconciled        value | null    ONLY here
result_recorded   false           ONLY here
rc                1
```

Conversely `invocation_record_id`, `result_record_id`, `succeeded`,
`result_digest` and `result_artifact_reference` never appear on the unresolved
path. **Read the key set, not `rc` alone** — Stage 1 also returns 1 on success.

## 12. If a future authorised resume returns unresolved again

Do not re-run `execute` a third time, do not touch Podman by hand, do not
synthesize a `CRES`, do not edit lifecycle records. Return the output.

**Governed recovery would now be usable**, which was not true before this
sequence of corrections:

- the Generation-16 fix makes `unresolved_invocations` discover CINV-000002 by
  its canonical record id (proven live at G11-BC-C §3.2)
- the Generation-17 cwd correction means the reconciliation subprocess no longer
  fails on an unreachable working directory — which is what defeated it last
  time

It is still a privileged action needing its own authorisation, and it is not
authorised here.

### 12.1 Proposed evidence remediation — operator decision, not performed

Not done in this checkpoint. Options, for the reviewer to choose:

1. **Reconstruct and record.** Write a G11-BB evidence file from its reviewed
   matrix and the observable installed digests, clearly labelled as a
   reconstruction with the date and the reason, and write a correctly-named
   G11-BC-E evidence file from the corrected ceremony. Both are new writes to
   `/root` and need authorisation.
2. **Accept the loss, documented.** Leave `/root` as it is and treat this report
   plus G11-BB-R as the record. The mislabeled file stays, which is the part I
   like least.

I recommend (1), because a file that says `ceremony g11-bb-helpers` /
`runtime_generation 14` while containing G11-BC-E's transaction is worse than
either a correct file or no file.

## 12.2 Validation

```
FOCUSED
  BC-E helper ceremony  PASS   BB helper ceremony   PASS
  helper ceremony       PASS   transition-action    PASS
  podman-backend        PASS   reconcile entrypoint PASS
  supervision           PASS   recovery-discovery   PASS
  reconciliation        PASS   result contract      PASS
  generation 16 / 17 installers  PASS
  shellcheck            clean

LOCAL_FULL   PASS  137/137 steps
LOCAL_QUICK  PASS  112/112 steps
```

## 13. Production non-mutation

```
HOST_GENERATION 17
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
lifecycle    launch_authorized     INVOCATION_SEQ 2     CRES_COUNT 0
handoff      out/ cschott:cschott 0700 — observed, NOT altered
Fabric 3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b
Trust  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f
sudoers      two grants, verify absent
nothing in the runtime store modified since 2026-09-10 05:00
```

```
NO EXECUTE. NO RECOVER. NO CRES. NO CONTAINER MANIPULATION.
NO HANDOFF CHOWN OR CHMOD. NO FABRIC, TRUST OR SUDOERS MUTATION.
NO EVIDENCE FILE REWRITTEN.
```

## 14. Reviewer gate

The installed deployment is correct and I recommend accepting it on the §1
evidence, which does not depend on the defective file.

**Resume must not be authorised until the evidence question is settled** (§12.1).
That is a records decision, not a technical blocker — but it is the gate §8
defines, and the deployment's own attestation artifact currently names the wrong
ceremony and the wrong generation.

```
CINV_000002_RESUME_AUTHORISED  NO
RECOVERY_AUTHORISED            NO
PRODUCTION_INVOKE_AUTHORISED   NO
```
