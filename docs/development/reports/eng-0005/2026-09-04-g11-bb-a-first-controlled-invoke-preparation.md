# ENG-0005 G11-BB-A — first controlled production invocation, preparation

**Status: prepared, awaiting reviewer approval.** No production invocation was
performed. No `CINV` or `CRES` exists. Nothing was mutated by this preparation —
the Fabric aggregate and the capability-runtime baseline are byte-identical
before and after every check.

Follows **[G11-BA](2026-09-03-g11-ba-sudoers-and-final-invoke-preflight.md) §11**,
which installed and verified the two narrow privileged grants.

Branch `arch/eng-0005-execution-transition`, HEAD `e4ab3f0`.

---

## 1. The single most important thing on this page

**`invoke` exits `1` when it succeeds.** Derived from the released source, not
inferred:

```python
def command_invoke(args) -> int:
    """One governed invocation, prepared and then stopped."""
    ...
    decision = prepare_invocation(...)     # adapter=None, execution_binding=None
    _emit({...})
    # Every outcome reachable here is a governed negative: a preparation that
    # cannot proceed, a refusal, a replay, or a conflict.
    return EXIT_DENIED
```

`prepare_invocation` executes *"only if it may be"*, and needs **both** an
adapter and an execution binding. `command_invoke` supplies neither, by
construction, so a fully successful preparation returns `status: prepared` with
`reason: no_authorised_adapter` — and the command exits `1`.

**`EXIT_DENIED` here does not mean the invocation failed.** It means the
coordinator prepared it and stopped, which is the whole design. By that point
`CINV-000001` is **allocated, written and immutable**, and the package is staged.

**Consequence for the ceremony: do not run these commands under `set -e`, and do
not re-run `invoke` because it "failed".** Re-running spends nothing — the
request identity would classify as a replay or a conflict — but reading exit `1`
as failure and abandoning the ceremony would leave a real `CINV-000001` behind
with no result. The operator must read `status` and `invocation_record_id` from
the JSON, not the exit code.

## 2. The ceremony is three stages, not one

Derived from `tools/capability/cli.py`. There is no single "invoke production"
command; the authority is split across three surfaces on purpose.

| # | command | what it does | writes | exit on success |
| --- | --- | --- | --- | --- |
| 1 | `invoke` | verifies selected evidence, current eligibility, scope; stages the package; **allocates and commits the immutable `CINV`** | `CINV-000001` | **`1`** (see §1) |
| 2 | `authorise-launch` | lifecycle transition to `launch_authorized`; seals the execution profile; publishes the handoff | authorisation + handoff | `0` |
| 3 | `execute` | drives the privileged transition → worker → rootless Podman; **coordinator writes the immutable `CRES`** | `CRES-000001` | `0` iff `succeeded` |

**Why the split matters.** `execute` *"decides nothing about whether execution is
permitted. That was decided twice already."* It takes **one `CINV`** and no
adapter, backend, binding, image or argv — *"there is no flag for any of them,
which is what makes 'the caller does not choose what runs' a property of the
surface rather than a rule about it."*

**Stages 2 and 3 do not take `--store-root`.** They resolve fixed deployment
roots from the released source: `CAPABILITY_RUNTIME_ROOT
=/data/kyri/capability-runtime`, `HANDOFF_ROOT =/data/kyri/capability-handoff`,
`AUTHORITY_ROOT =/var/lib/kyri/implementation-authority`.

## 3. Where the privileged grants are actually used

Only stage 3 crosses the boundary, through `kyri_exec_launcher.HelperLauncher`:

```
SUDO               = "/usr/bin/sudo"
TRANSITION_HELPER  = "/usr/libexec/kyri-exec-transition"
RECONCILE_HELPER   = "/usr/libexec/kyri-exec-reconcile"
PERMITTED_HELPERS  = frozenset({TRANSITION_HELPER, RECONCILE_HELPER})
```

It builds `sudo <helper> <CINV>` from constants plus one validated `CINV`, with
a closed environment. That is exactly the shape the two installed grants admit —
digest-pinned path, one `^CINV-[0-9]{6}$` argument — so the grants and the
launcher agree by construction rather than by coincidence. The launcher *"can
only ask; a host without the grants gets a refusal."*

The coordinator never passes an image, a Podman argv or a result path. The
worker derives everything from the `CINV` and the profile the transition seals
onto descriptor 3, *"which this side never sees and could not forge."*

## 4. Preflight, re-run immediately before this preparation

```
would_accept                     true
would_refuse_reason              null
current_eligibility              true
eligibility_reasons              []
scope_permits_operation          true
supervision_ready                true
helper_compatibility             compatible
helpers_blocking                 []
coordinator_identity_authority   true
execution_identity_authority     true
execution_identity_account       kyri-capability
predicted_invocation_record_id   CINV-000001
implementation_id                CIMP-000001
execution_image_id               5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
execution_backend                python-podman-v1
argv_contract                    fixed-python-entrypoint-v1
package_tree_sha256              sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
would_stage_at                   …/staging/tree-sha256-6f2282c5…
```

`INVOKE_PREFLIGHT = PASS`. Every required field holds.

**Non-mutation:** Fabric `7c53efcd…aa6c8e96` and capability-runtime
`36a13cd7…d5f5d1a6` byte-identical before and after.

`execution_image_available: false` remains an observation-point artefact, not a
missing image — BA §6. It was answered from the execution identity in BA §11.1
and passed.

**Next IDs, derived from the live runtime store rather than assumed:**

```
CapabilityStore('/data/kyri/capability-runtime').peek_next_id(...)
  capability-invocation  ->  CINV-000001
  capability-result      ->  CRES-000001
```

These match the expectation, and were derived, not copied.

## 5. Time window, read live

```
now                          2026-09-04T18:26:24-05:00
CADV-000004.valid_until      2026-09-06T12:02:14-05:00   inside: True
CINST-000003.admitted_until  2026-09-06T12:02:14-05:00   inside: True

WINDOW_REMAINING             41h 35m   (149749 s)
```

Both read from the stored records at this preparation, not copied from prior
reports. The window is ample for a governed ceremony with room for review,
execution and, if needed, recovery.

## 6. Pre-invoke baselines

Captured `2026-09-04T18:28:26-05:00`. These are the comparison basis for BB-B.

```
[fabric]        7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
[trust]         53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f
[evidence]      62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507
[impl-auth]     191bbd63cef88778fc1bdd27dd35e71d96f76cd7be0b44ffa22222885d7023f1
[artifacts]     ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df
[runtime-lib]   5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84  (79 .py)
[libexec]       489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86
[identity]      bf825c7c380082dd21b574ba82d4e507392485ef1ba1b19c1fd7dc1f5fa09f61
[cap-runtime]   36a13cd7c439952b5d9b2706215c79b1695e0783d564466f1ae3857cd5f5d1a6
[sudoers]       f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
```

```
staging entries       0        transitions            0
handoff entries       0        locks                  0
CINV records          0        execution state        0
CRES records          0        mutations              0
*.seq counters        0        quarantine (store)     0
                               quarantine-reservations 0
quota counters        cadm-counter 000000   cmut-counter 000000000000
```

**Pre-existing containers, recorded separately so they cannot be mistaken for
invoke residue.** Operator-attested as `kyri-capability`: only `trackb-*`
containers from roughly three weeks ago. **No `kyri-CINV-*` container exists.**

The coordinator cannot enumerate Podman and must not gain the authority to —
`recover` is explicit that *"Podman is never enumerated: the coordinator has no
authority to ask what containers exist and must not gain any."* So the container
baseline is operator-attested by design, and must be **re-confirmed immediately
before stage 1** and again after stage 3.

## 7. Expected delta, derived from source

Not asserted as exact filesystem mutation — derived from the surfaces each stage
touches.

**Stage 1 `invoke`**

- `capability-invocations/CINV-000001.yaml` — **CREATE**, immutable
- `sequences/capability-invocation.seq` — **CREATE** (none exists today)
- `staging/tree-sha256-6f2282c5…/` — package staged from the approved artifact
  root
- the invocation identity lock is taken and released; it already exists

**Stage 2 `authorise-launch`**

- lifecycle state advanced to `launch_authorized`; execution profile sealed with
  a `profile_digest` and a `commitment_digest`
- a handoff published under `/data/kyri/capability-handoff`
- journalled projection under `execution/`
- **`CINV-000001` itself is not rewritten** — supersession and lifecycle are
  recorded beside it, not on it

**Stage 3 `execute`**

- `sudo /usr/libexec/kyri-exec-transition CINV-000001` → privileged transition →
  credential drop → worker → rootless Podman container under the execution
  identity
- supervisor conducts the protocol conversation and concludes a terminal outcome
- **coordinator** writes `capability-results/CRES-000001.yaml` — immutable — and
  `sequences/capability-result.seq`
- reconciliation proves container disposal; `disposal_proven: true`
- quota state under `execution/` may advance

**The worker writes no Capability Runtime record and cannot**: it has *"no store,
no allocator and no path to one."* Result authority stays with the coordinator.

## 8. Success criteria

The reviewer's criteria, each mapped to where the evidence comes from.

| criterion | evidence |
| --- | --- |
| `CINV-000001` exists, immutable | stored record; digest captured before stage 2 and re-compared after stage 3 |
| `CRES-000001` exists, terminal | stored record; `record_terminal_result` is the only writer |
| `CINV` adapter identity populated | stored `CINV` field |
| `CINV` not mutated after execution | digest identical pre-/post-stage-3 |
| `CRES` binds the correct `CINV` | `CRES.invocation_record_id` |
| `CRES` binds instance / package / operation | stored fields against `CSEL-000002` / `CINST-000003` / `CPKG-0001` / `execute` |
| `succeeded` propagated | `execute` JSON **and** the stored `CRES`, compared |
| result digest present | `terminal.result_digest`, non-null |
| result artifact reference null **by design** | **confirmed in source**: `execute_supervised` passes `result_artifact_reference=None` literally. Null is correct and expected; a non-null value would be the anomaly |
| no result ambiguity | exactly one `CRES`, `capability-result.seq = 1` |
| no orphan `kyri-CINV-*` container | operator `podman ps -a` as the execution identity |
| worker reaped | supervisor trace `worker_reaped` |
| reconciliation clean | `disposal_proven: true`; `recover` reports ready |
| Fabric / Trust unchanged | aggregates vs §6 |
| selection / route / instance / advertisement unchanged | per-record digests |
| sudoers unchanged | `[sudoers]` aggregate vs §6 |
| helper bytes unchanged | `[libexec]` and `[runtime-lib]` aggregates vs §6 |

**Zero exit with no governed result must not be reported as success.** The
released path names this `result-missing`: `collector.Classification.RESULT_MISSING`
and `records.REASON_RESULT_MISSING = "result-missing"`, which is one of
`CCON-0001`'s declared `failure_modes`. Both modules are **installed and import
cleanly** — checked, because BA §7 found two undeployed modules and one of them
(`contract_outcome.py`) mentions `result-missing`. It has **no importer** and is
not on this path, so the live `result-missing` determination is served entirely
by deployed code. If stage 3 reports `succeeded: false` with reason
`result-missing`, that is a **correct governed outcome**, not a ceremony failure
— and it must be reported as such.

## 9. Failure and recovery boundary

Documented before authorisation so nothing is improvised.

**The one governed recovery surface is `capability recover`.** It:

- enumerates invocations carrying an adapter identity with no terminal result —
  *"exactly what a killed worker or a killed coordinator leaves behind"*;
- reconciles their containers through the privileged reconcile helper;
- **writes nothing** — no result is synthesised and the invocation record is
  never touched;
- is **idempotent** — *"Reconciliation treats absence as success, so a second
  pass proves the same thing and changes nothing."*

```bash
python3 -m tools.capability.cli recover --expected-uid 1000 --expected-gid 1000
```

Exit `0` iff the execution-safety gate reports ready.

| situation | operator response |
| --- | --- |
| **worker death** | Stage 3 returns `status: unresolved`, `result_recorded: false`, exit 1. **A refusal writes nothing — by design.** Run `recover`. Do not re-run `execute`. Do not synthesise a result. |
| **timeout** | Same path. The supervisor concludes and the trace reports how far the conversation got. `recover`, then report. |
| **reconciliation failure** | `recover` exits non-zero with the unresolved findings. **Stop and report.** Do not escalate privileges and do not touch Podman by hand. |
| **container orphan** | `recover` is the remedy. It reconciles through the governed reconcile grant. |
| **`CRES` write failure** | The invocation stays unresolved and enumerable. Report the exact error. Do not retry `execute` — the terminal outcome was already concluded once and re-driving it would conclude a second time. |
| **ambiguous terminal state** | Capture the full stage-3 JSON including `protocol_states`, `worker_reaped`, `disposal_proven`, `reconciled`. Run `recover` for the container question only. Escalate to the reviewer. |

**Prohibited during production, without an explicit reviewed authorisation:**

- `podman kill`, `podman rm`, `podman stop` or any manual container mutation;
- re-running `execute` after an unresolved outcome;
- writing, editing or deleting any `CINV` or `CRES`;
- installing any further sudoers grant, including
  `/etc/sudoers.d/kyri-exec-verify`, which must remain **absent** (BA §0.1);
- deleting the capability-runtime scaffolding (BA §0.2).

Leaving an invocation unresolved is the honest state and the one the recovery
enumeration can still act on. Closing it by hand destroys that.

## 10. The operator ceremony

**Not to be run until the reviewer approves.** Every argument is derived from the
released parser and the live store; none is invented.

### Stage 0 — payload, and a last look

```bash
# A coordinator-owned approved payload root: uid 1000, not group/other writable.
mkdir -p -m 0700 /data/kyri/work/g11bb
cat > /data/kyri/work/g11bb/first-invoke.json <<'JSON'
{
  "operation": "execute",
  "arguments": {
    "count": 1,
    "label": "g11bb-first-controlled-production-invoke"
  },
  "note": "ENG-0005 G11-BB: the first controlled production invocation."
}
JSON
chmod 0600 /data/kyri/work/g11bb/first-invoke.json
sha256sum /data/kyri/work/g11bb/first-invoke.json
stat -c '%n %U:%G %a %s bytes' /data/kyri/work/g11bb /data/kyri/work/g11bb/first-invoke.json

# Container baseline immediately before the ceremony.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require: only pre-existing trackb-*; NO kyri-CINV-*
```

The payload must be a regular file with a **single hard link**, owned by uid
1000, under a root owned by uid 1000 that is not group- or other-writable —
`open_trusted_regular_file` checks every one of those on the descriptor. The
**same** payload file is passed to stages 1 and 2; its digest binds them.

### Stage 1 — prepare and allocate `CINV-000001`

**Expect exit `1` with `status: prepared`. That is success — see §1.**

```bash
cd /opt/schott-platform
python3 -m tools.capability.cli invoke \
  --store-root /data/kyri/capability-runtime \
  --expected-uid 1000 --expected-gid 1000 \
  --fabric-root /var/lib/kyri/fabric \
  --fabric-expected-uid 1000 --fabric-expected-gid 1000 \
  --approved-artifact-root /var/lib/kyri/artifacts \
  --trusted-source-uid 0 \
  --staging-root /data/kyri/capability-runtime/staging \
  --coordinator-uid 1000 \
  --approved-payload-root /data/kyri/work/g11bb \
  --payload-source-uid 1000 \
  --payload-file first-invoke.json \
  --invocation-id g11bb-first-controlled-invoke \
  --selection-id CSEL-000002 \
  --instance-id CINST-000003 \
  --package-id CPKG-0001 \
  --operation execute \
  --trust-store-root /var/lib/kyri/trust \
  --actor primary-platform-operator \
  --request-id g11bb-first-production-invoke \
  --requested-at "$(date -Is)" ; echo "rc=$?"
```

Require in the JSON: `status: prepared`, `invocation_record_id: CINV-000001`,
`staged_path` non-null, and `reason: no_authorised_adapter`. **Stop and report if
`status` is anything else.** Then capture the record before going on:

```bash
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml
cat /data/kyri/capability-runtime/sequences/capability-invocation.seq
```

### Stage 2 — authorise the launch

```bash
python3 -m tools.capability.cli authorise-launch \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000001 \
  --cimp CIMP-000001 \
  --approved-payload-root /data/kyri/work/g11bb \
  --payload-file first-invoke.json \
  --package-entrypoint main.py ; echo "rc=$?"
```

Require `rc=0`, `lifecycle_state: launch_authorized`, `handoff_published: true`,
`resumed: false`, and a `profile_digest` / `commitment_digest`. The
`--package-entrypoint` is `main.py`, the sole file in the governed package tree
`kyri-execution-boundary-verification/1.0.0`.

### Stage 3 — supervised execution and the `CRES` write

**This is the first production execution.** It crosses the privileged boundary.

```bash
python3 -m tools.capability.cli execute \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000001 \
  --actor primary-platform-operator \
  --recorded-at "$(date -Is)" ; echo "rc=$?"
```

Require `status` terminal, `result_record_id: CRES-000001`, `succeeded: true`,
`result_digest` non-null, `result_artifact_reference: null` (by design, §8),
`disposal_proven: true`.

If it returns `status: unresolved` — **stop, do not re-run, go to §9.**

### Stage 4 — return this evidence

```bash
# records
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml \
          /data/kyri/capability-runtime/capability-results/CRES-000001.yaml
cat /data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml
cat /data/kyri/capability-runtime/capability-results/CRES-000001.yaml
cat /data/kyri/capability-runtime/sequences/capability-invocation.seq
cat /data/kyri/capability-runtime/sequences/capability-result.seq

# governed recovery gate — must report ready, and writes nothing
python3 -m tools.capability.cli recover --expected-uid 1000 --expected-gid 1000 ; echo "rc=$?"

# no orphan container
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'

# nothing else moved
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
find /var/lib/kyri/trust  -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
find /usr/libexec -name 'kyri-exec-*' -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
find /etc/sudoers.d -maxdepth 1 -type f -printf '%f %u:%g %m %s\n' | sort | sha256sum
python3 -c "
import sys; sys.path.insert(0,'/usr/lib/kyri/python')
from tools.capability.execution import helpers
c=helpers.compatibility(); print(c.verdict, len(helpers.REQUIRED_HELPERS), len(c.blocking))"
```

Require Fabric `7c53efcd…aa6c8e96`, Trust `53605e4e…7828b63f`, libexec
`489f108d…952bea86`, sudoers `f837d592…495da1a9`, helpers `compatible 8 0` — all
matching §6.

## 11. Preconditions, all met

```
BA_RESULT                     ACCEPTED
LAUNCH_GRANT_INSTALLED        YES
RECONCILE_GRANT_INSTALLED     YES
VERIFY_GRANT_PRESENT          NO
SUDOERS_POLICY                PASS
IMAGE_AUTHORITY               PASS
HELPER_COMPATIBILITY          compatible   8 declared, 0 blocking
FABRIC_CHAIN_FRESH            YES   CADV-000004 → CINST-000003 → CROUTE-0003 → CSEL-000002
FABRIC_VALID                  YES   findings 0
TRUST_VALID                   YES   problems 0
CURRENT_ELIGIBILITY           PASS  ELIG-1..12
INVOKE_PREFLIGHT              PASS
PREFLIGHT_MUTATES             NO
WINDOW_REMAINING              41h 35m
CINV_NEXT                     CINV-000001   (derived)
CRES_NEXT                     CRES-000001   (derived)
PRE_BB_BASELINE               36a13cd7c439952b5d9b2706215c79b1695e0783d564466f1ae3857cd5f5d1a6
PRODUCTION_CINV_COUNT         0
PRODUCTION_CRES_COUNT         0
BB_PREPARED                   YES
PRODUCTION_INVOKE_AUTHORISED  NO
```

## 12. Next

1. **Reviewer approves the ceremony in §10**, in particular the exit-code
   semantics in §1 and the recovery boundary in §9.
2. Operator runs stages 0–4 and returns the complete output of each.
3. **G11-BB-B** — independent verification of `CINV-000001` and `CRES-000001`
   against §8, with content-delta accounting against the §6 baselines.
4. Afterwards, the deferred runtime-generation remediation for
   `verification.py`, `result_content.py` and `contract_outcome.py` (BA §0.1),
   before `kyri-exec-verify` is ever granted.

---

## 13. Reviewer ruling — Stage 1 only

```
BB_PREPARATION                       ACCEPTED   (2026-09-04)
PRODUCTION_INVOKE_STAGE_1_AUTHORISED YES
AUTHORISE_LAUNCH_AUTHORISED          NO
EXECUTE_AUTHORISED                   NO
```

The `command_invoke` `EXIT_DENIED` behaviour is accepted as current released
ceremony semantics for Stage 1.

**Process exit status alone must not be interpreted.** Stage 1 counts as
successful only when the structured result proves `status=prepared` and
`reason=no_authorised_adapter` **and** exactly `CINV-000001` is allocated and
stored. Exit `1` is expected *only* in company with that exact result and that
exact record. Any other pairing stops the ceremony.

**Do not wrap the invoke command in `set -e`.**

Stage 0 may create only the reviewed operator work area. Stage 1 may perform
only the released `invoke`. **Not to be run:** `authorise-launch`, `execute`,
`recover`, or either privileged helper directly.

### 13.1 Live re-check immediately before returning the command

```
host now                     2026-09-04T18:36:36-05:00
CADV-000004.valid_until      2026-09-06T12:02:14-05:00   inside: True
CINST-000003.admitted_until  2026-09-06T12:02:14-05:00   inside: True
WINDOW_REMAINING             41h 25m   (149137 s)        expired: False
current eligibility          true, unmet []
CINV_NEXT (live allocator)   CINV-000001
CINV / CRES records          0 / 0
capability-runtime           36a13cd7…d5f5d1a6   unchanged
fabric                       7c53efcd…aa6c8e96   unchanged
/data/kyri/work/g11bb        absent — Stage 0 creates it
```

### 13.2 Which CINV fields Stage 1 does and does not populate

Derived from `_invocation_body` in `tools/capability/evidence.py`, so the
post-Stage-1 check demands neither too much nor too little.

**Written at the prepared stage:**

```
invocation_record_id   CINV-000001
invocation_id          g11bb-first-controlled-invoke
request_id             g11bb-first-production-invoke
selection_id           CSEL-000002
instance_id            CINST-000003
capability_package_id  CPKG-0001
contract_id            CCON-0001
capability_id          CAPDEF-0001
operation              execute
actor                  primary-platform-operator
payload_digest         sha256:…
binding_digest         sha256:…
effect_class           computational
artifact_digest        sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
staged_path            /data/kyri/capability-runtime/staging/tree-sha256-6f2282c5…
requested_at           <the instant passed>
evidence.outcome       prepared
```

**Deliberately *not* populated at Stage 1 — do not require these yet:**

- **`adapter_identity` is `null`.** `command_invoke` supplies no adapter, and
  `_invocation_body` writes the argument through unchanged. A populated
  `adapter_identity` is what `recover` looks for to identify an invocation whose
  execution was authorised, so at the prepared stage it **must** be null. A
  non-null value here would be the anomaly.
- **`CIMP-000001` does not appear in the `CINV` at all.** The implementation is
  bound at Stage 2, where `--cimp` is an argument to `authorise-launch`. The
  earlier success criterion *"CINV binds … implementation=CIMP-000001"* is a
  **post-Stage-2** property, not a Stage-1 one, and requiring it after Stage 1
  would fail a correct record.
- No result, no handoff, no profile or commitment digest, no lifecycle
  authorisation.

### 13.3 What Stage 1 is permitted to mutate

Everything else is a finding. Compared against `PRE_BB_BASELINE`
`36a13cd7…d5f5d1a6`:

```
CREATE   capability-invocations/CINV-000001.yaml
CREATE   sequences/capability-invocation.seq            (none exists today)
CREATE   staging/tree-sha256-6f2282c5…/                 the staged package tree
TOUCH    sequences/invocation_identity.lock             taken and released; already exists
```

Required to remain **unchanged**: Fabric `7c53efcd…aa6c8e96`, Trust
`53605e4e…7828b63f`, `CADV-000004`, `CINST-000003`, `CROUTE-0003`,
`CSEL-000002`, libexec `489f108d…952bea86`, sudoers `f837d592…495da1a9`,
identity authorities, runtime library.

Required to remain **absent**: any `CRES`, any handoff entry, any
`kyri-CINV-*` container, any transition/lock/state/mutation entry under
`execution/`, any privileged helper execution.
