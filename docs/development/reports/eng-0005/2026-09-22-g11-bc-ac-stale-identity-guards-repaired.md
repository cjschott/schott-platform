# G11-BC-AC — two stale identity guards repaired, and what they had been hiding

**Date:** 2026-09-22
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `db8eecf69252da6950f35c58dcf8118c65c064c6`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — both suites run and pass. Production was not mutated and Stage 3 was not executed.

---

## 1. RED first: the guards, reproduced before anything was changed

Both suites derived the identity they require with

```
sed -n 's/^COORDINATOR_UID = \([0-9]*\)$/\1/p' provisioning/execution/kyri-exec-transition.py
```

Measured on `db8eecf`, before the repair:

| | |
|---|---|
| value extracted | **empty string**, length 0 |
| `test-capability-execution-profile-transport.sh` | `HOST_ONLY_SKIP … not the coordinator identity ` — exit 0 |
| `test-capability-execution-g61-verification.sh` | `HOST_ONLY_SKIP … not the coordinator identity ` — exit 0 |

Both printed `It must run as uid ; this process is uid 1000.` — the expected
identity blank. `f9d94ce` removed the compiled-in `COORDINATOR_UID = 1000`
because it was true of `schai` only by coincidence, and the extraction has
matched nothing ever since.

**STALE_GUARD_REPRODUCED = YES.**

## 2. The repair

`tests/lib/host-only.sh` grew one reusable guard,
`host_only_requires_coordinator_identity <repository-root>`. It adds no parsing
of its own: it opens `/etc/kyri/coordinator-identity.json` no-follow, takes the
status from the descriptor it opened, and hands both to
`load_coordinator_authority` — **the same reader the privileged helper uses**,
which judges ownership before it reads the bytes as authority and enforces the
closed schema and the version. The path and the size bound are read from the
policy module rather than retyped.

No uid is hard-coded anywhere, and there is deliberately nothing to fall back
to. The three outcomes are kept apart:

| condition | behaviour |
|---|---|
| authority absent or unreadable | `HOST_ONLY_SKIP`, exit 0 — not this deployment |
| authority present but refused by the governed reader | **FAIL**, exit 1 |
| empty or non-numeric answer | **FAIL**, exit 1 — that empty string *is* the original bug |
| resolved | compared against the running uid, as before |

Measured, with the real reader against fixture authorities:

```
absent authority (CI)            rc=0 | HOST_ONLY_SKIP  this deployment publishes no coordinator identity authority
malformed authority              rc=1 | FAIL: the coordinator identity authority did not verify: TransitionRefused: …
present but not root-owned       rc=1 | FAIL: the coordinator identity authority did not verify: TransitionRefused: …
real governed authority          rc=0 | BODY ENTERED as uid 1000
```

Ownership is judged before the bytes are parsed, which is why the malformed
fixture reports the ownership refusal — that ordering is the released reader's,
not this helper's.

**One defect of my own, caught and fixed.** The first version read `$?` after a
bare command substitution. Every suite runs under `set -Eeuo pipefail`, which
aborts the function on a failing substitution *before* `$?` can be read, so an
absent authority killed the suite with the reader's exit status instead of
skipping. The assignment now carries `|| _ho_rc=$?`. Without that fix CI would
have gone red for the wrong reason; the branch table above is the proof it does
not.

**IDENTITY_SOURCE = `/etc/kyri/coordinator-identity.json`, read through
`kyri-exec-transition.py`'s own `load_coordinator_authority` (ownership +
closed schema + version), with no compiled-in fallback.**

## 3. GREEN: what the suites revealed when they finally ran

Both entered their bodies — and both failed heavily. They had been skipping
since `f9d94ce`, so nobody had updated them through two deliberate production
changes.

| | first real run | after repair |
|---|---|---|
| `profile-transport` | 18 pass / **36 fail** | **54 pass / 0 fail** |
| `g61-verification` | 51 pass / **23 fail** | **74 pass / 0 fail** |

### 3a. Signature and fixture drift — the bulk of it

- `policy_for()`, `execution_record()`, `verify_only()` and `success_record()`
  all gained a required keyword-only `identity`, with no default, precisely so
  no signature can produce a policy or a record without one.
- `worker.WORKER_UID` / `WORKER_GID` were removed; the execution identity comes
  from `/etc/kyri/execution-identity.json` and the record builders read
  `identity.uid` / `identity.gid`.
- `policy_mod.ENVIRONMENT` became `execution_environment(identity)`.
- The fixtures had never grown two backend primitives the transition now calls:
  **`fchown`** (§13's output-leaf transfer) and **`chdir`**.
- The fixture backends opened governed roots `O_RDONLY`. Production uses
  `O_PATH`, because an anchor for `openat` needs *search*, not read, and
  `/etc/kyri` is `0711` by design. The released code carries a comment saying
  `O_RDONLY` "refused whenever this ran after" — the fixture still had it.
- `scene()` published no `out` leaf, and no `/etc/kyri`. It now hands the real
  `/etc/kyri` over as itself: the transition refuses an authority not owned by
  root, which a fixture cannot fabricate. That is exactly why these suites are
  host-only and gate on the coordinator identity first.

None of this weakened an assertion. Where the transition must really transfer
the output leaf and then **verify the transfer took effect**, the policy is
retargeted at this process (`local(policy)`), because the only transfer an
unprivileged process may make is to itself — the established pattern from
`test-capability-execution-transition-action.sh`. The governed numbers are
still asserted, from the policy object the released code built:
`assert (policy.worker_uid, policy.worker_gid) == (IDENTITY.uid, IDENTITY.gid)`.

### 3b. Three assertions whose premise the refactor voided

These are the ones that needed judgement, and they are reported rather than
buried:

1. **The source-ordering scans** (`profile-transport`). They scanned
   `perform_transition` for `setgroups`/`setgid`/`setuid`/`no_new_privs`. Those
   moved into `drop_privilege`, which `perform_transition` calls — so every
   marker was absent and the case had been reporting *"the transition never
   calls setgroups"*, unrun. The scan now splices `drop_privilege`'s body in at
   its call site, so it reads the order the process actually performs. Intent
   preserved exactly; it also now covers `transfer_output_leaf`.

2. **"the production worker still refuses for want of a runtime backend"**
   (`g61`) and **the token ban in "the worker entrypoint validates…"**
   (`profile-transport`). Both required the production worker to be **G6-gated**
   — to bind no Podman and no `create_argv` at all. **G6 is open.** It was opened
   deliberately at G6.1, the worker binds the governed backend at the privilege
   boundary, and **Stage 3 executes through exactly that binding.** The voided
   ban is dropped rather than quietly inverted. What survives is what it was
   protecting: the worker binds the backend *without restating the container
   contract* — `oci_image_id`, `--mount`, `mounts`, `tmpfs`, `pids_limit`,
   `network` and `subprocess` are all still absent, verified.

3. **"the governed handoff root is opened once"** (`profile-transport`). The
   handoff root is now opened **twice** — once by §13's output-leaf transfer and
   once by profile-source authentication — and `/etc/kyri` once per authority
   read. The invariant that matters is *where* roots come from, so the case now
   asserts every `open_directory` target is a compiled-in governed root and that
   the execution root is opened exactly once. A caller-supplied root would still
   show up here.

**No production defect was found.** The ordering the released transition
performs was verified directly and is intact:

```
perform_transition:  quota.apply → transfer_output_leaf → authenticate_profile_source
                     → seal_profile_object → place_profile_descriptor
                     → close_extra_descriptors → verify_profile_descriptor
                     → drop_privilege → execve
drop_privilege:      setgroups → setgid → setuid → credentials
                     → set_no_new_privs → (readback)
```

and the recorded call order from a real run is

```
open_directory ×3, fchown, open_directory ×2, close_extra_descriptors, chdir,
setgroups, setgid, setuid, credentials, set_no_new_privs, get_no_new_privs,
credentials, execve
```

**The Stage-3 ceremony was not changed.** Nothing these suites proved
contradicts it.

## 4. Coverage matrix — real kernel versus injected

### REAL

| capability | evidence |
|---|---|
| governed Podman container execution | G11-BC-AB E2E, re-run here: **42/42**, real containers from the exported archive |
| container security controls | observed on a real container at G11-BC-AB (image, name, label, network none, read-only root, cap-drop ALL, no-new-privileges, pids, memory, CPU, user, userns keep-id, tmpfs, mounts) |
| **memfd sealing** | `profile-transport` EMPIRICAL A — a real sealed object refuses every mutation, including through a reopen; a retained writable source descriptor cannot change the authenticated bytes |
| **FD 3 across a real `execve`** | `profile-transport` EMPIRICAL B — a real subprocess `execve`s and the memfd arrives on FD 3 with seal mask **15** and the expected digest and length; without the explicit `FD_CLOEXEC` clear the child receives nothing; a caller that pre-opens FD 3 has it replaced |
| **descriptor closure, kernel-observed** | `g61` — `require_descriptor_closure()` in real subprocesses: `3<` alone yields `(0,1,2,3)`; an extra `7<` is refused naming `[7]`; a missing FD 3 is refused |
| **`no_new_privs` kernel readback** | `g61` — under real `setpriv --no-new-privs` the kernel reports `1`; without it the check refuses with `no_new_privs is '0'`. Read from `/proc/self/status`, not from the transition's say-so |
| credential *check* against real credentials | `g61` — `require_dropped_credentials` reads this process's real `getresuid`/`getresgid` and refuses, naming the required identity |
| profile authentication, sealing, placement | `profile-transport` — below a real directory descriptor, so open/stat/read/hash/copy/seal/place is production code running for real |
| output-leaf transfer verification | real `fchown` + production's post-transfer re-stat, for the one transfer an unprivileged process may make |

### INJECTED / STRUCTURAL

| capability | how it is covered, and its limit |
|---|---|
| **`setgroups` / `setgid` / `setuid`** | recorded against an injected backend. Order and refusal are proven; **no real credential transition occurs** |
| **saved-ID verification** | the "privilege survived the drop" case supplies a *synthetic* `Credentials` with the saved id still root. Real `getresuid` is exercised only in the coordinator-refusal direction — **a genuine saved-ID drop is never crossed** |
| **quota application** | injected `Quota`; the suite's own comment says it "establishes nothing real". Call site, ordering (before the drop) and refusal are proven; no real project quota is set or verified |
| **root-only ownership transfer** | performed only as self→self. Transferring to the governed execution identity requires root and **is never performed** |
| `execve` of the worker | recorded; the real `execve` proven in EMPIRICAL B is the test's own, not the transition's |
| privileged transition as a whole | never run under real privilege; no `sudo`, no production helper invoked anywhere in this checkpoint |

### What remains first-live-use in production Stage 3

1. A **real privilege drop** — `setgroups`/`setgid`/`setuid` actually changing
   this process's credentials, and the saved-set id genuinely becoming
   unrecoverable.
2. **Root-only ownership transfer** of the output leaf to the execution
   identity.
3. **Real quota application and verification** against the derived project.
4. The privileged helper running **under `sudo` as root**, end to end, with the
   real `execve` into the production worker.

Everything downstream of that boundary — the container, its controls, the
protocol, the conclusion and the disposal — has now been exercised for real.

## 5. Verification

| Run | Result |
|---|---|
| `test-capability-execution-profile-transport.sh` | **54/54 PASS**, rc 0, **no skip** |
| `test-capability-execution-g61-verification.sh` | **74/74 PASS**, rc 0, **no skip** |
| Real container E2E | **42/42 PASS**, ran |
| Stage-3 rehearsal | **160/160 PASS** |
| Transition-action | **48 PASS** |
| Reconcile-entrypoint | **12 PASS** |
| Quick validator | **131/131**, passed — zero `HOST_ONLY_SKIP` |
| Full validator | **156/156**, passed — **zero `HOST_ONLY_SKIP`** |
| Clean-clone full validator | CLONE_RESULT (see §5a) |
| ShellCheck (CI-pinned 0.9.0) | clean, rc 0 |
| GitHub CI | **6/6 success** at `b1bc7ee` — CI, CodeQL, Gitleaks, Semgrep, ShellCheck, Trivy |

**Skipped tests, explicitly.** The full validator reported **no
`HOST_ONLY_SKIP` at all** — the first fully-unskipped run in this chain. Both
repaired suites ran inside it and passed, alongside the container E2E:

```
17339: Capability execution Pass 3B-ii sealed profile transport validation passed.
21035: Capability supervised execution E2E validation passed.
21171: Capability execution G6.1 verification validation passed.
```

Before this checkpoint the same validator skipped two suites; at G11-BC-AB it
skipped those two and nothing else. Neither is among the skips on `schai` now,
because there are none.

The clean-clone run skips by design: its suites pin `/opt/schott-platform` and
correctly decline a clone at another path, and the coordinator-identity guard
behaves the same way anywhere the authority is absent. Those skips are listed
with the clean-clone result below.

### The guard, proven on a real non-production machine

GitHub CI is the case the helper's "absent authority" branch exists for, and the
run at `b1bc7ee` shows it taking that branch and keeping the pipeline green:

```
HOST_ONLY_SKIP  test-capability-execution-profile-transport.sh  this deployment publishes no coordinator identity authority
HOST_ONLY_SKIP  test-capability-execution-g61-verification.sh   this deployment publishes no coordinator identity authority
```

Exit 0, with the reason stated rather than an empty string — and CI green, which
is what the `set -e` fix above is what makes true.

### 5a. The clean-clone run, and the first attempt that refused

The first clean-clone attempt **stopped at step 66**, on the Generation-20
installer:

```
FAIL: --verify-source refused:  STOP: the working tree is not clean;
      a ceremony runs from reviewed bytes only
```

That refusal was **correct, and had nothing to do with this repair**. The
installer ceremony is pinned to `/opt/schott-platform` and reads its reviewed
source from there even when the suite itself is driven from a clone — so it was
reporting on the *main* checkout, where this report was still an untracked file.
The clone's own tree was clean throughout.

It is recorded here rather than quietly re-run: a ceremony refusing to read an
unreviewed working tree is the behaviour that exists, and the fix was to commit
the report and run it again from reviewed bytes.

CLONE_RERUN

## 6. Production, before and after

| | before | after |
|---|---|---|
| Runtime aggregate | `648066f6…e133a` | `648066f6…e133a` |
| Fabric aggregate | `a87c2010…12e5` | `a87c2010…12e5` |
| `CINV-000003` | `launch_authorized` | `launch_authorized` |
| Occupancy | 2 of 2 | 2 of 2 |
| `CRES-000002` | absent | absent |
| `capability-result.seq` | 1 | 1 |
| `cmut` / `cadm` | `000000000010` / `000002` | `000000000010` / `000002` |
| Transitions | 7 | 7 |

No production helper was invoked. No capability was executed. Every container
created in this checkpoint lived in a disposable Podman store under `/tmp`.

As at G11-BC-AB, the governed `kyri-capability` Podman store cannot be read from
this account, so the absence of a production `kyri-CINV-000003` container
remains established indirectly rather than observed.

## 7. Current Fabric authority

Re-run at the end of the checkpoint, through the released verifier:

```
evaluated_at: 2026-09-22T05:10:45-05:00
supported = True, reason = None, eligibility_reasons = ()
CSEL-000004 -> CINST-000006 -> CPKG-0001 -> CCON-0001, operation execute
```

`CADV-000007` is still the unsuperseded head — it carries `supersedes:
CADV-000006` and no `CADV-000008` exists — with
`valid_until: 2026-09-23T06:00:00-05:00`. Roughly **25 hours** remained at the
time of checking. Authority was not renewed in this checkpoint.

**CURRENT_FABRIC_AUTHORITY = PASS. CURRENT_ELIGIBILITY = PASS.**

## 8. Ceremony integrity

`provisioning/execution/g11-bc-aa-cinv-000003-stage-3-ceremony.txt` is
byte-identical to the reviewed blob `62388a27028e92ff2269713a157a0e6e41e6baf5`.
Nothing the newly-running suites proved contradicts it — the one thing they did
contradict was their own obsolete belief that G6 was still closed, and Stage 3
depends on it being open.

**STAGE3_CEREMONY_CHANGED = false.**

## 9. Actions not performed

Stage 3 was not executed. The production privileged transition was not invoked.
No `CRES` was created. Stage 2 was not re-run. No `CINV` was abandoned,
recovered or cleaned. Lifecycle architecture was not changed. Fabric, Trust,
Artifact authority and Platform Evidence were not altered. Root Authority was
not mounted. The image was not re-exported. ENG-0006 was not begun.

## 10. For the reviewer

The guards are repaired and the two suites prove what they were written to
prove. Three assertions were reworked because a production refactor had voided
their premise, and each is named in §3b with what replaced it — the G6 pair in
particular were asserting the *opposite* of the architecture Stage 3 runs on,
and are the clearest illustration of what an unconditional skip costs.

The stranded-lifecycle decision and the `CADV-000007` expiry are unchanged from
G11-BC-AB and still belong to the reviewer.
