# G11-BC-AB — the Stage-3 container E2E evidence gap, closed

**Date:** 2026-09-21
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `b9d8e922d653307588032e4580c491cfab09d9f7`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the gap is closed. Stage 3 was not executed and nothing in production was mutated.

---

## 1. What this checkpoint was for

G11-BC-AA prepared Stage 3 and stated one gap plainly: the rehearsal never ran
the real governed container. The OCI archive that
`tests/test-capability-supervised-execution-e2e.sh` needs was gone from `/tmp`,
so that suite reported `HOST_ONLY_SKIP` while the validators stayed green.

This checkpoint closes that gap and nothing else. It is preparation and
verification only.

## 2. Production, verified before anything was run

Read-only, measured with the installed Generation-20 runtime rather than taken
from the acceptance. Lifecycle states and occupancy were read **through the
released library** — `cli._anchored()` against the real backing-store
configuration at `/etc/kyri/backing-store.json` — not by parsing the transition
files by hand.

| | |
|---|---|
| Runtime aggregate | `648066f6e79af23732eb6131bf772579bad898e71179def5ae4dabb6475e133a` — matches |
| Fabric aggregate | `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` — matches |
| `CINV-000001` / `-000002` / `-000003` | `launch_authorized` / `abandoned` / `launch_authorized` |
| Occupancy | **2 of 2** (`MAXIMUM_SLOTS = 2`) |
| `capability-invocation.seq` / `capability-result.seq` | 3 / 1 |
| `cmut-counter` / `cadm-counter` | `000000000010` / `000002` |
| `CRES-000002` | absent — only `CRES-000001.yaml` exists |
| Transitions | 7 |

Repository authority `b9d8e92`, working tree clean, branch as expected. The
reviewed Stage-3 ceremony blob is
`62388a27028e92ff2269713a157a0e6e41e6baf5` in both the commit and the working
tree — unchanged, and **not changed by this checkpoint**.

## 3. The export

The operator performed it; this account could not. The `kyri-capability` store
is mode `0750`, uid 999 / gid 987, and the operator account is not in that
group; `sudo -n -l` carries only the two production helpers as `NOPASSWD`, and
both are out of bounds here. No archive existed anywhere on the host.

The archive that arrived:

```
/tmp/kyri-g11-ai-oci-a999e0e2c2bd/cimp-000001-5cee2b53.oci-archive.tar
25 MiB, kyri-capability:kyri-capability
sha256 2730c64ef9aac21b3f57ed0fde61a6db13cac6b11dc5bbbfffcf97a4f912127e
```

Digest verified on receipt. It is evidence material only: it was loaded into
disposable Podman stores under `/tmp` and never into the governed store, and
the image store and capability runtime were not modified. The image was not
re-exported.

## 4. The suite RAN

```
=== isolated import ===
Loaded image: sha256:5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

Six parts, **42 assertions, every one PASS, none failed, no skip**. (The one
string matching `FAIL` in the transcript is the verdict token
`RECONCILIATION_FAILURE_FAILS_CLOSED=YES`, not a failure.)

| Part | What ran |
|---|---|
| 1 | supervised success against a real container — completed, succeeded, digest carried, started proven, protocol reached `collected`, worker reaped, disposal proven, container absent afterwards |
| 2 | a workload producing nothing — `completed`, `succeeded False`, no digest invented |
| 3 | the worker SIGKILLed mid-run — no outcome concluded, no classification invented, reconciliation invoked for the exact CINV, orphan proven absent, identity verified before removal |
| 4 | cleanup that cannot be proven is not claimed — disposal not proven, nothing concluded |
| 5 | the unresolved invocation blocks readiness — `not-ready`, recovery, no result synthesised, second pass idempotent |
| 6 | a supervised orphan discovered from lifecycle authority — discovered by state, not adapter identity |

Verdict:

```
SUPERVISED_SUCCESS=PASS
WORKER_SIGKILL_ORPHAN_RECOVERED=PASS
ORPHAN_CONTAINER=NO
RECONCILIATION_FAILURE_FAILS_CLOSED=YES
SERVICE_READINESS_GATE=PASS
INTERRUPTED_CRES_CREATED=NO
```

**STAGE3_E2E = PASS. REAL_CONTAINER_EXERCISED = true.**

## 5. The Generation-20 controls, observed on the real container

The E2E suite builds its container argv from the production
`worker.create_argv(binding)`, so the container it creates is constructed by the
released code. But the suite itself only inspects `.State.Status`; it does not
assert the individual controls. So those were observed directly: the same
governed binding, the same production `create_argv`, a real container created in
a disposable store and inspected live, then removed.

| Control | Observed |
|---|---|
| exact governed image | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` |
| container name | `kyri-CINV-000042`, from the CINV alone |
| governed profile correlation | label `io.kyri.invocation-id=CINV-000042` |
| network none | `NetworkMode = none` |
| read-only root | `ReadonlyRootfs = true` |
| cap-drop ALL | `CapAdd []`; `CapDrop` = the full resolved set (CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, NET_BIND_SERVICE, SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT) |
| no-new-privileges | `SecurityOpt [no-new-privileges]` |
| pids limit | `64` |
| memory limit | `268435456` (256m), swap identical — no swap headroom |
| CPU limit | quota `50000` / period `100000` = 0.5 |
| execution user | `65532:65532` |
| user namespace | `keep-id`, IDMappings `[0:1:65532 65532:0:1 65533:65533:4]` |
| tmpfs controls | `/tmp:size=16m,mode=1777,noexec,nosuid,nodev,rw,rprivate,tmpcopyup` |
| package mount | `/kyri/package` **ro** |
| payload mount | `/run/kyri/input/payload` **ro** |
| output writable only where intended | `/kyri/output` **rw**, and it is the only writable bind |
| argv contract | `[/usr/bin/python /kyri/package/main.py]` |

**`--pull=never` is the one control that is not observable after creation.** It
is present in the production argv and is proven behaviourally by the Stage-3
rehearsal's absent-image refusal, but Podman does not record it on the created
container, so it is reported as argv-and-behaviour evidence, not as an inspected
property.

`start_now` protocol, container start, terminal collection and
disposal/reconciliation are exercised for real in Part 1 and Parts 3–6, through
the released `ExecutionSupervisor`: the released code sends `START_NOW` only
after `VERIFIED_PROFILE` and reachable exactly once, and the run reached
`collected` with disposal proven.

## 6. The privileged transition — what is NOT covered, stated plainly

**The E2E provides no coverage of the privileged transition.** The suite says so
in its own header, and it is true: the worker half runs in a forked child as the
same unprivileged user, because a real drop needs root and would drive rootless
Podman into the production graphroot. No `sudo` is used and no privileged helper
is invoked anywhere in the suite.

So for the eleven items asked about in step 6 — quota application/verification,
output ownership transfer, sealed profile fd, extra descriptor closure, `chdir`,
`setgroups`, `setgid`, `setuid`, credential verification, `no_new_privs`
set/readback, and worker `exec` — **the E2E contributes nothing, and none of it
is claimed from the E2E.**

What does cover them, re-run here:

- `tests/test-capability-execution-transition-action.sh` — **48 assertions,
  passed.** It proves the ordering invariant (setgroups before setgid before
  setuid, credential verification before `no_new_privs`, `no_new_privs` before
  `exec`), the quota step on the output leaf *before* the credential drop, the
  `fchown` transfer in descriptor form only with refusal on a symlinked,
  non-directory or wrong-mode leaf, and `chdir` to a compiled-in safe directory
  with no caller-, environment- or payload-derived path.
- `tests/test-capability-execution-reconcile-entrypoint.sh` — **12 assertions,
  passed.** Descriptor closure: reconciliation closes to three descriptors and
  launch keeps four, and the closure really closes an extra inherited one.

**The honest limit on that coverage:** both suites drive the privileged module
against an **injected recording backend** — the suite's own comment describes the
quota component as establishing "nothing real". They prove the call sequence,
the order and the refusals; they do **not** exercise real kernel credential
transitions. Nothing in this checkpoint ran a real privilege drop, and the
production Stage 3 will be the first time that path runs for CINV-000003.

**PRIVILEGED_TRANSITION_COVERAGE = ordering, quota-before-drop, fchown
descriptor form, chdir and descriptor closure proven against an injected
recorder in two suites (60 assertions); NOT exercised by the E2E and NOT proven
against real kernel credential transitions.**

## 7. Verification

| Run | Result |
|---|---|
| Real container E2E | **42/42 PASS**, ran (no skip) |
| Stage-3 rehearsal | **160/160 PASS** |
| Transition-action suite | **48 PASS** |
| Reconcile-entrypoint suite | **12 PASS** |
| Quick validator | **131/131**, passed |
| Full validator | **156/156**, passed — **with the E2E running inside it** |
| Clean-clone full validator | **156/156**, passed — clone of the pushed commit **from the remote**, E2E ran and passed there too |
| ShellCheck (CI-pinned 0.9.0, host) | clean, rc 0 |
| GitHub CI | **6/6 success** at `b79cf8a` — CI, CodeQL, Gitleaks, Semgrep, ShellCheck, Trivy |

**Skipped tests, explicitly.** The full validator reported exactly **two**
`HOST_ONLY_SKIP`s, and `test-capability-supervised-execution-e2e.sh` is no
longer one of them — it ran inside the validator at line 20974 and passed:

- `test-capability-execution-profile-transport.sh`
- `test-capability-execution-g61-verification.sh`

both with the reason `runs as uid 1000, not the coordinator identity ` — with
the expected identity **blank**.

The **clean-clone** run reported 20 skips: the same two, plus 18 suites that
pin `/opt/schott-platform` and correctly decline to run against a clone at a
different path. That is the designed behaviour of
`host_only_requires_pinned_checkout`, not a regression. The E2E suite is **not**
among them — it ran and passed in the clean clone as well.

### A pre-existing defect in those two skip guards, reported not fixed

Both suites derive the identity they require with

```
sed -n 's/^COORDINATOR_UID = \([0-9]*\)$/\1/p' provisioning/execution/kyri-exec-transition.py
```

**That constant no longer exists.** G11-AH removed the compiled-in
`COORDINATOR_UID = 1000` from the privileged helper precisely because it was
true of `schai` only by coincidence; the coordinator identity now comes from
`/etc/kyri/coordinator-identity.json`, which on this host reads
`{"coordinator_account":"cschott","coordinator_uid":1000,...}`.

So the `sed` yields an empty string, `host_only_requires_identity ""` compares
`1000` against `""`, and the guard skips **unconditionally** — including on the
production host, where this process runs as uid 1000 and the suites would
otherwise run. Two suites that are supposed to be proven only by the local
validator are therefore proven nowhere, and the validator is green without them.

This is pre-existing, is not caused by this checkpoint, and is unrelated to
Stage 3 or to the ceremony — so it is reported here for a reviewer decision and
**was not fixed**, in keeping with this checkpoint being verification only. It
does not affect the Stage-3 evidence: neither suite covers the container path or
the privileged transition sequencing relied on above.

## 8. Production after all testing

Re-measured after every run above:

| | |
|---|---|
| Runtime aggregate | `648066f6e79af23732eb6131bf772579bad898e71179def5ae4dabb6475e133a` — unchanged |
| Fabric aggregate | `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` — unchanged |
| `CRES-000002` | absent |
| `capability-result.seq` | 1 |
| `CINV-000003` | `launch_authorized` |
| Occupancy | 2 of 2 |
| `cmut` / `cadm` | `000000000010` / `000002` |
| Transitions | 7 |
| Production `kyri-CINV-000003` container | none — see the limitation below |
| Stage 3 | not executed |

Every container created in this checkpoint lived in a disposable Podman store
under `/tmp` and was removed by its suite's own cleanup trap.

**One limitation, stated rather than papered over.** The governed
`kyri-capability` Podman store cannot be read from this account — that needs
the elevation BLOCK A performs, and this checkpoint did not elevate. So the
absence of a production `kyri-CINV-000003` container is established indirectly:
`execute` was never invoked, no privileged helper was called, the runtime
aggregate is unchanged, and every container this checkpoint created was in a
disposable store at a different graphroot. A direct observation of the governed
store is BLOCK A's job and belongs to the Stage-3 run itself, which pins a
witness under 900 s old.

## 9. Current Fabric authority

Asked of the released verifier at `2026-09-21T11:34:09-05:00`:

```
supported = True, reason = None, eligibility_reasons = ()
CSEL-000004 -> CINST-000006 -> CPKG-0001 -> CCON-0001, operation execute
```

`CADV-000007` is still the unsuperseded head — it carries `supersedes:
CADV-000006` and there is no `CADV-000008` — with
`valid_until: 2026-09-23T06:00:00-05:00`. Authority has not moved and has not
expired; roughly 42 hours remained at the time of checking. Authority was **not
renewed** in this checkpoint.

**CURRENT_FABRIC_AUTHORITY = PASS. CURRENT_ELIGIBILITY = PASS.**

## 10. The ceremony was not changed

`provisioning/execution/g11-bc-aa-cinv-000003-stage-3-ceremony.txt` is
byte-identical to the reviewed blob `62388a27028e92ff2269713a157a0e6e41e6baf5`.

**Nothing this checkpoint measured contradicts the ceremony or the Stage-3
assumptions.** The container controls observed on a real container are exactly
those the ceremony and the G11-BC-AA reconstruction describe, including the
image, the name, the limits, the mounts and the argv contract. No discrepancy
was found, so there was nothing to stop for.

**STAGE3_CEREMONY_CHANGED = false.**

## 11. The stranded lifecycle

Unchanged and untouched, as instructed. A successful Stage 3 is still expected
to create `CRES-000002` while leaving `CINV-000003` at `launch_authorized` and
occupancy at 2 of 2. Nothing here solved it, no `CINV` was abandoned, recovered
or cleaned, no cleanup was added to Stage 3, and lifecycle semantics were not
altered. It remains a post-execution architectural decision for the reviewer.

## 12. Actions not performed

Stage 3 was not executed in production. `capability execute` was not run against
production. No `CRES` was created in production. Stage 2 was not re-run. No
`CINV` was abandoned, recovered or cleaned. Fabric, Trust, Artifact authority and
Platform Evidence were not altered. `MAXIMUM_SLOTS` is unchanged at 2. No runtime
record was hand-edited. Root Authority was not mounted. The image was not
re-exported. The reviewed ceremony was not modified. ENG-0006 was not begun.

## 13. Readiness

The gap G11-BC-AA named is closed: the real governed container path runs, passes,
and carries every Generation-20 control that is observable. Two things the
reviewer should still weigh, both carried forward unchanged from G11-BC-AA:

1. **The stranded outcome.** After Stage 3 both slots are held by invocations
   that cannot advance.
2. **The authority window.** `CADV-000007` expires 2026-09-23T06:00:00-05:00.

And one this checkpoint adds:

3. **The privilege drop is still unexercised against a real kernel.** It is
   proven by ordering and refusal against an injected recorder, which is the
   strongest evidence available off the privileged path — but production Stage 3
   will be its first real run.
