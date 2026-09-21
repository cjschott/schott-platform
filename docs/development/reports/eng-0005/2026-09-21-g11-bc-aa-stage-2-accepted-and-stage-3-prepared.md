# G11-BC-AA — Stage 2 verified, and CINV-000003 Stage 3 prepared

**Date:** 2026-09-21
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `4950af3debfbb92574e6f9a554a0603f707dba8d`
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — Stage 3 is prepared and rehearsed, not run. Nothing in production was mutated.

---

## 1. Source and ceremony authority

Stage 2 was performed from
`provisioning/execution/g11-bc-z-cinv-000003-stage-2-ceremony.txt`, prepared at
G11-BC-Z and accepted by the reviewer. The installed runtime was Generation 20
throughout.

## 2. Stage 2, verified independently

Read-only. Measured with the installed runtime rather than taken from the
acceptance.

| | |
|---|---|
| Runtime aggregate | `648066f6e79af23732eb6131bf772579bad898e71179def5ae4dabb6475e133a` — matches |
| `CINV-000003` | `launch_authorized` |
| `CINV-000001` / `CINV-000002` | `launch_authorized` / `abandoned` |
| Occupancy | **2 of 2** |
| Transitions / mutations | 7 / 10 |
| `cmut-counter` / `cadm-counter` | `000000000010` / `000002` |
| `capability-invocation.seq` / `capability-result.seq` | 3 / 1 |
| `CRES-000002` | absent |

Every Stage-2 artefact is byte-identical to what the G11-BC-Z rehearsal
predicted, which is the strongest statement available about a ceremony:

| artefact | SHA-256 |
|---|---|
| `execution/CINV-000003/launch-authorisation` | `885801a1362dcf99faaacdcdf457b7a9cecac99104012c24cfb6cfa5284f31df` |
| `transitions/CINV-000003.000001` (`reserved`) | `5c0a67d794864a810e3773e5646f1e8a38bc561263ad6c02e1dd7c8f9b8f5a9f` |
| `transitions/CINV-000003.000002` (`launch_authorized`) | `ba51ae422004b4024a8143611779660beb803ccbfdb6a5caacdfed5cb648d3e3` |
| `CMUT-000000000008/9/10` | the two transitions and the projection, each pinning the digest above |
| handoff `payload` / `profile` / `package/main.py` | `591d4b0d…` / `f6696e0d…` / `683e25ed…` |

All four immutable records and both `CADM`s are unchanged.

**Mutation accounting, by content.** A copy with the execution directory, the
lock, the two transitions and the three `CMUT`s removed and `cmut-counter`
rewound to `000000000007` reproduces

`76bf8f993c4af1cdce88ecb93d0e72f88177ba56f7e6d407ab4f0166aa0e1cd7`

exactly. Nothing unexplained.

**STAGE2_VERIFICATION = PASS.**

## 3. Stage 3, reconstructed from the installed Generation-20 bytes

Read from `/usr/lib/kyri/python`, the released tests, the ADRs, and the three
accepted Stage-3 attempts in this chain.

**Command**

```
cd /usr/lib/kyri/python && python3 -m tools.capability.cli execute \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000003 \
  --actor primary-platform-operator \
  --recorded-at "$(date -Is)"
```

One `CINV` and nothing else: no `--adapter`, `--backend`, `--image`, `--argv`,
`--binding` or `--store-root`. The runtime root is compiled in, and
`supervised_binding` compiles in the execution root it reads the authorisation
from.

### rc is not the verdict

`command_execute` returns `EXIT_SUCCESS if terminal.succeeded else EXIT_DENIED`.
**rc 1 means two different things:** a supervision that refused and wrote
*nothing*, and an execution that concluded and recorded a result that did not
succeed. They are distinguished only by the JSON — `status: "unresolved"` with
`result_recorded: false` for the first. The ceremony reads the JSON first and
the exit status second.

### Expected JSON on success

| field | value |
|---|---|
| `cinv`, `invocation_record_id` | `CINV-000003` |
| `status` | `prepared` (the decision's own status field) |
| `result_record_id` | `CRES-000002` |
| `succeeded` | `true` |
| `reason` | `null` |
| `result_digest` | `sha256:fd2d58e99bae82f32ce320a3d3ac2a35b6e679b87432b2aedd9de1efa92cbad7` |
| `disposal_proven` | `true` |

### The privileged chain, in order

`kyri_exec_launcher` → `sudo` → `/usr/libexec/kyri-exec-transition CINV-000003`
→ identity + policy + launch authentication → **quota applied and verified
against the project the CINV derives** (no fallback to unquotaed execution) →
**output-leaf ownership transfer** (root only, before the drop) → profile
authenticated, sealed and placed on descriptor 3 → **extra descriptors closed**
→ profile descriptor verified → **`chdir` to the governed working directory,
then `setgroups`/`setgid`/`setuid`, verified in every credential component, then
`no_new_privs` set and read back** → `execve` of the worker. The transition
never returns.

### The container

Name `kyri-CINV-000003`, derived from the `CINV` and nothing else — no attempt
suffix, so a second attempt would need a second identity. Created with
`--pull=never`, `--network none`, `--read-only`, `--cap-drop ALL`,
`--security-opt no-new-privileges`, `--pids-limit 64`, `--memory 256m`,
`--cpus 0.5`, `--user 65532:65532`, `--userns keep-id`, a 16 MiB
`nodev,noexec,nosuid` tmpfs, the package and payload bound read-only and the
output leaf read-write. Image `5cee2b5305b5…`, governed by `CIMP-000001`.
Profile timeout 30 s, grace 2 s.

### The conversation

`created` → `verified_profile` → **`start_now`** → `started` → `terminal` →
`collected`. `start_now` is the only message the coordinator sends and is
reachable exactly once, after the verified profile is correlated against the
sealed one. The container's disposal is proven by reconciliation on **every**
path before any outcome is returned.

### The mutation — and the one thing it does not do

**Stage 3's entire capability-runtime mutation is one `CRES` and one sequence
increment.** Measured on a byte copy: `capability-results/CRES-000002.yaml` and
`capability-result.seq` `1 → 2`. Nothing else changes.

**It writes no lifecycle transition, and that is specified behaviour.** The
journal is written by `authorise_launch` before the privilege boundary and is
immutable thereafter; the states past `launch_authorized` are worker-side
protocol states that exist on the wire and never in the journal. G11-BC-I
established this (`LIFECYCLE_WITHOUT_TERMINAL_TRANSITION_INTENTIONAL=YES`), and
the evidence confirms it: **every `CMUT` ever spent in this store is a Stage-2
transition, a Stage-2 authorisation, or the abandonment.** CINV-000002's Stage 3
completed and journalled nothing.

**So there is no capacity release.** `capacity.release` requires a lifecycle
that reached `cleaned`; nothing reaches it, and no released operator verb calls
cleanup or release at all.

### What the store will be left in

After Stage 3, `CINV-000003` will hold a terminal result and still stand at
`launch_authorized`, holding its execution slot. **That is exactly the condition
`CINV-000002` was administratively abandoned for** under ADR-0015, reason
`terminal-result-lifecycle-stranded`. Occupancy stays 2 of 2 and both slots will
then be held by invocations that cannot move.

This is stated in the ceremony before the command, and nothing in this
checkpoint acts on it. It is an architectural decision for the reviewer.

### Idempotency and recovery

A second `execute` is refused **before the privilege boundary** by
`require_no_terminal_result` — the G11-BC-K correction. Measured: the launcher
is never called, no identity is spent. A refusal writes nothing, deliberately,
so the invocation stays in the enumeration recovery and the readiness gate act
on; an `adapter-error` record would close the question without answering it.

## 4. Current authority before Stage 3

Asked of the released verifier at the moment of checking:

```
supported = True, reason = None, eligibility_reasons = ()
CSEL-000004 -> CINST-000006 -> CPKG-0001 -> CCON-0001 -> CAPDEF-0001, operation execute
```

`CADV-000007` is the unsuperseded head, `CROUTE-0006` the route head,
`CSEL-000004` still selects `CINST-000006`, Fabric aggregate `a87c2010…`
unchanged.

**CURRENT_FABRIC_AUTHORITY = PASS. CURRENT_ELIGIBILITY = PASS.**

**The authority expires 2026-09-23T06:00:00-05:00 — about 45 hours from this
checkpoint.** `execute` re-runs no governed decision and would not notice, so
BLOCK B asks the verifier at run time. Stage 3 before then, or renew and
re-prepare.

## 5. The payload, and what it must produce

The payload asks for `verify-execution-boundary`, which is the correction
G11-BC-J made after `CRES-000001` recorded `provider-error` because the payload
had asked for `execute`. The capability reads exactly one field — `operation` —
and refuses anything else.

The result is deterministic, and the rehearsal **ran the released package
against the published canonical payload** rather than predicting it:

```
{"capability":"kyri-execution-boundary-verification",
 "checksum":"57b6b93ffd50cce4df4c8af4fd40d9b16494b884f666490257c66ff2dd274de1",
 "operation":"verify-execution-boundary",
 "payload_digest":"591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3",
 "result_schema_version":1}
```

281 bytes, SHA-256 `fd2d58e99bae82f32ce320a3d3ac2a35b6e679b87432b2aedd9de1efa92cbad7`.
That is the digest the verdict must carry and the ceremony pins it.

## 6. The rehearsal

`tests/test-capability-cinv-000003-stage-3-rehearsal.sh` — **160 assertions**,
host-only.

- The released contract asserted from the installed bytes: the surface, the
  exit-status rule, the container argv's every security control, the container
  name, and that the mutation journal has never held anything but transitions
  and authorisations.
- The released package run against the published payload: exactly the pinned
  bytes, checksum and digest; and the historical class re-refused — a payload
  asking for `execute` is rejected, nonzero, writing nothing.
- The coordinator half driven for real over the released protocol, through the
  released encoder, against a byte copy: `CRES-000002`, `succeeded true`, the
  pinned digest, `capability-result.seq` `1 → 2`, lifecycle and occupancy
  unchanged, no `CMUT`, no transition, every other record byte-identical, and
  the whole mutation proved by reconstruction.
- Eight ways it can end, each measured: `provider-error`, `result-missing` and
  `timeout` record a result that does not claim success; disposal unproven, a
  worker that verified another image, a worker that changed container, a worker
  that never spoke, and a worker that died after being authorised to start each
  write **nothing** and leave the invocation unresolved.
- The duplicate-result gate: refused, and the launcher never called.
- BLOCK B run whole against fixtures, and twenty-two sabotages each refusing
  for its own reason with no traceback.

### What the rehearsal could not exercise, stated plainly

**The container half did not run.** The governed execution image lives in the
`kyri-capability` Podman store, which this account cannot read, and the exported
OCI archive `tests/test-capability-supervised-execution-e2e.sh` uses is gone
from `/tmp` — that suite currently reports `HOST_ONLY_SKIP`, so the full
validator is green without it running.

So the worker half here is a scripted peer speaking the released protocol. What
is proven is the coordinator's half — the conversation, the start authority, the
conclusion, the record and every refusal. The container itself is asserted from
the released bytes and covered behaviourally by the transition-action and
reconcile suites.

**Recommendation for the operator, before Stage 3:** re-export the image
archive as `kyri-capability` so the end-to-end suite runs again:

```
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman save --format oci-archive \
  -o /tmp/kyri-g11-ai-oci-a999e0e2c2bd/cimp-000001-5cee2b53.oci-archive.tar \
  5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

(The directory must be created first and be readable by the operator account.)
That is a read of the image store, not a change to it, and it would let the one
suite that runs a real governed container run again before the real one does.

## 7. The ceremony

`provisioning/execution/g11-bc-aa-cinv-000003-stage-3-ceremony.txt`, prepared
and **not executed**. Three blocks, as at Stage 2: observation, the gates, and
the one irreversible command. BLOCK C is not rehearsable for the same reason —
`execute` and `supervised_binding` both compile in their roots, so a
substitution would redirect the gates and not the mutation.

It pins: the five installed Generation-20 digests; the current Fabric authority
through the released verifier at run time; the runtime baseline `648066f6…`; all
four immutable records and both `CADM`s; the launch-authorisation and its
fields; the handoff's three digests and five modes; the payload and staged tree;
both sequences, both counters and the transition count; the lifecycle and
occupancy 2 of 2; and a witness under 900 s old recording no `kyri-CINV-000003`
container and the expected image.

Afterwards it reads the JSON before the exit status, pins the verdict and the
`CRES` fields, re-checks every record that must not have moved, and states the
stranded outcome rather than leaving it to be discovered.

## 8. Stage 2 is spent

`authorise-launch` was not re-run. Durable facts: `CINV-000003` is
`launch_authorized`, its launch-authorisation exists at `885801a1…`, the handoff
exists with the three pinned digests, and the invocation sequence is 3. No
historical whole-runtime aggregate is pinned in spent mode beyond the one Stage 3
itself will move.

## 8b. Two suites had to move to spent mode with it

Both re-ran their ceremony against a fixture cut from production, and Stage 2
landing made that impossible for one and wrong for the other:

- `test-capability-cinv-000003-stage-2-rehearsal.sh` drove `authorise_launch`
  against a copy. The copy now carries CINV-000003's execution state, so the
  released code refuses with `CapacityExhausted` — working exactly as designed.
- `test-capability-cadm-000001-correction-rehearsal.sh` reconstructed the
  pre-correction store and checked its aggregate. Stage 2 happened *after* the
  correction, so the reconstruction no longer reproduces it.

Reconstructing further would mean subtracting every later stage's artefacts
from a hand-kept list — the defect corrected at G11-BC-Y in eight other suites.
Both are now spent mode: durable facts, the ceremony's own refusal on a durable
fact, and no historical whole-store aggregate. Each keeps the behaviour that is
still live — Stage 2 keeps the repeat that resumes and writes nothing, the
correction keeps its conflict and resume refusals.

## 9. Actions not performed

Stage 3 was not run in production. No payload was executed in production. No
`CRES` was created in production. Stage 2 was not re-run. `CINV-000001` was not
reclaimed. Fabric, Trust, Artifact authority and Platform Evidence were not
altered. `MAXIMUM_SLOTS` is unchanged at 2. No runtime record was hand-edited.
Root Authority was not mounted. ENG-0006 was not begun.

## 9b. Verification

| Run | Result |
|---|---|
| Quick validator | **131/131**, passed |
| Full validator | **156/156**, passed |
| Clean-clone full validator | **156/156**, passed |
| ShellCheck (CI-pinned 0.9.0) | clean |

Suites: Stage-3 rehearsal 160, Stage-2 rehearsal 34 (spent mode), correction
rehearsal 31 (spent mode).

Production after every run: runtime `648066f6…`, Fabric `a87c2010…`, no
`CRES-000002`, `capability-result.seq` still 1.

## 10. Readiness for Stage 3

Ready, with three things the reviewer should decide first:

1. **The stranded outcome.** After Stage 3 both slots are held by invocations
   that cannot advance. Nothing in the released path fixes that; ADR-0015
   abandonment is the only instrument, and using it is a decision, not a step.
2. **The 45-hour authority window.** `CADV-000007` expires 2026-09-23T06:00.
3. **The unexercised container half.** The recommendation in §6 is cheap and
   would close it.
