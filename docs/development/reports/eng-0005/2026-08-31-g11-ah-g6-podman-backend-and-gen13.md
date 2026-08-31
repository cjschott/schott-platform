# ENG-0005 G11-AH — deterministic preflight, deployment coordinator authority, and a stop

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `8e7b5c3eff09d765091c735f3070e3c329799b5f`
**Implementation commits:** `4a7fdf3627966a007adee17d1a059817d4f0d224`,
`f9d94ced7b3f444cd0affbd6362d524bdfaff85b`

Two deliverables landed and one stop is called.

**Phase 1 is done and the baseline is restored.** The invoke-preflight suite no
longer depends on the wall clock or on a live lease: it derives its evaluation
instant from the records its own fixture holds. Quick **80/80**, full
**105/105**, both green.

**Phases 2–6 are done.** `COORDINATOR_UID = 1000` is gone from the privileged
helper. The coordinator is now a deployment identity read from root-owned
authority, with no constant to fall back to and no environment escape hatch.
Twenty-eight assertions pin it, including that a deployment approving uid 1001
accepts 1001 and refuses 1000 — which is what proves the rule follows the
authority rather than the number.

**Phases 20–22 are blocked, and that blocks the backend behind them.** The
governed image `5cee2b53…` exists only in the `kyri-capability` store, which is
`0750 kyri-capability`. The coordinator cannot read it, and every route to its
bytes — `podman save`, copying the storage tree, re-pulling — needs privilege
this checkpoint was not granted, or produces a different image. Phase 22 says in
terms: *"If exporting/copying the image requires privileged or mutating
operations not already authorized: STOP for reviewer ruling rather than
improvising."* That is the situation, so I stopped.

Phases 7–19 could be written without it, but not **verified** without it. A
container-execution path across a privilege boundary, shipped green on argv
assertions alone, is precisely the ambiguous success Phase 17 forbids. I did
not write it. §9 states exactly what a ruling would unblock.

One finding the reviewer should see early: **the installed privileged helper is
two commits behind the repository, and was before this checkpoint began.** §6
traces it to `cfb0edd`. Nothing changed it here.

Production mutation: none.

---

## 1. Starting authority

| Check | Observed |
| --- | --- |
| Branch | `arch/eng-0005-execution-transition` |
| HEAD / origin | `8e7b5c3e…`, identical, `0 0` divergence |
| Working tree | clean |
| G11-AG report and implementation | both ancestors of HEAD |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Fabric store | 21 files, `bcb2559b…f15e` |
| CIMP-000001 | `ecb38d80…9991b`, no retirement |
| CINST / CADV / CROUTE / CSEL | 2 / 3 / 2 / 1 |
| `/etc/sudoers.d` | `README` only — G3 closed |
| `/etc/kyri` | `drwx--x--x root root` — present, not readable by the coordinator |

## 2. The expired-chain test failure, and the correction

### What was wrong

`test-capability-invoke-preflight.sh` shaped its fixture by copying the **live**
production Fabric and then evaluated it at the wall clock:

```python
at = instant or datetime.now(CT).isoformat()
```

When the production window closed at `2026-08-30T16:19:19-05:00`, six assertions
began failing for a reason unrelated to what they test. The RED, reproduced at
the start of this checkpoint:

```
FAIL: a currently eligible binding would be accepted (False, admission-window-not-open)
FAIL: it reports the package tree digest without publishing it
FAIL: it reports current eligibility as its own field
FAIL: and the rehearsal names the scope refusal (admission-window-not-open)
FAIL: and reports the scope gate as failed
FAIL: and reaches the same conclusion the rehearsal reported (refused/...)
exit 1
```

Every one is a *semantic* assertion — scope gating, digest reporting, rehearsal
and write agreeing — and none of them is about lease freshness.

### The correction

The instant is now **derived from the records the fixture holds**, not from the
clock and not from a literal:

```python
opens  = max(instance["admitted_at"],   advertisement["observed_at"])
closes = min(instance["admitted_until"], advertisement["valid_until"])
return (opens + (closes - opens) / 2).isoformat()
```

Both windows are half-open, so the intersection's midpoint is strictly inside
both. The helper refuses outright if the interval is empty, rather than
returning an instant that would quietly test nothing.

Three properties this buys:

- **Lease-independent.** The production chain may expire, be renewed, or be
  renewed with a different length; the suite reads whatever the fixture holds.
- **No literal to rot.** A pinned `2026-08-29T12:00:00` would have had to be
  edited at CINST-000003. A future binding with different windows yields a
  different instant and the same verdicts.
- **Still exercises the real path.** The fixture is still production-shaped and
  the released CLI still runs; only the clock reference moved.

The one case that deliberately evaluates *outside* the window keeps its fixed
2027 instant. It was already deterministic and still refuses for its own reason,
so G11-Y's coverage is untouched.

None of the forbidden shortcuts was used: production was not renewed, no window
was widened, expiry is not ignored, and eligibility is not monkeypatched.

### A second defect, found by restoring the baseline

Full validation had never reached its own summary while the preflight suite was
red. With that fixed it ran to the end and immediately failed:

```
FAILED: step count mismatch — declared 103, executed 104.
```

G11-AG added a full-only step and left `TOTAL_STEPS` at 103. The aborted run
never reached the check that would have caught it. Corrected to 104, and then to
105 for this checkpoint's suite.

## 3. Restored baseline

| Run | Steps | Result |
| --- | --- | --- |
| `run-validation.sh --quick` | **80/80** | **passed** |
| `run-validation.sh` (full) | **105/105** | **passed** |

Both measured after the coordinator-authority work, not before. Committed
independently as `4a7fdf36` before any other change, as the brief required.

## 4. Coordinator authority architecture

### Where it lives, and why there

`/etc/kyri/coordinator-identity.json`, `root:root`, writable by nobody else.

Not a new pattern. `/etc/kyri/backing-store.json` already carries provisioned
host authority under exactly this rule — *"Config is provisioned, never
generated… A malformed config is a refusal, not a prompt to write a fresh one"*
— and `/etc/kyri` is already `root:root` and non-descendable by the coordinator.
Phase 2 asked whether an existing authority should be reused rather than
duplicated; the answer is that the *directory* and its rules are reused, while
the record is separate because it answers a different question and is read by a
different consumer at a different privilege.

### The contract

Three fields, closed:

| Field | Type | Rule |
| --- | --- | --- |
| `schema_version` | int | exactly `1`; a bool is refused before the comparison |
| `coordinator_uid` | int | `0 < uid < 2**31`; bool refused; **0 refused by name** |
| `coordinator_account` | str | POSIX portable characters, ≤ 32, no surrounding space |

Bounded at 4096 bytes before parsing. Duplicate keys refused rather than
collapsed — the same rule the launch record gets, and for the same reason: a
dictionary has already destroyed the evidence that a record said two different
things about who the coordinator is.

`uid 0` is refused explicitly. Root is the identity the helper already holds; a
coordinator that is root is not a boundary.

### Why the uid is authority and the name is not

The kernel fact the helper can check is `st_uid` on a descriptor it already
holds. A name would have to be resolved through NSS *at the privileged
boundary* — a lookup the helper must not depend on, through a database an
attacker who reached it could aim.

The account name is carried only because sudoers grants are written in names.
`sudoers_principal()` takes the `CoordinatorAuthority` **type**, which only
`load_coordinator_authority` can construct, so a look-alike mapping is
structurally unusable rather than merely discouraged. That is what stops the
grant and the boundary from drifting apart.

### What was deliberately not added

Phase 4 cases 9 and 10 ask for refusals when a launch record or execution
profile carries a coordinator uid differing from the authority. **Neither record
has such a field**, and neither gained one.

Coordinator identity is deployment authority, not per-invocation authority. A
field inside the launch record is an assertion the *caller* writes; ownership of
the published objects is a kernel fact the caller cannot forge, and it is
already what the helper checks. Adding the field would have created a second,
weaker path to the same answer and made the boundary look stronger while being
weaker. Derived from the schemas rather than assumed — `LAUNCH_RECORD_SCHEMA`
has seven fields and none is an identity.

## 5. The identity matrix

RED first: four structural assertions failed before any source moved, and the
suite then aborted because `load_coordinator_authority` did not exist.

| Case | Expectation | Result |
| --- | --- | --- |
| authority uid 1000, caller 1000 | accept | **PASS** |
| authority uid 1001, caller 1001 | accept | **PASS** |
| authority uid 65534, caller 65534 | accept | **PASS** |
| authority 1000, caller 1001 | refuse | **PASS** — *owned by the wrong identity* |
| authority 1001, caller 1000 | refuse | **PASS** — 1000 has no standing of its own |
| absent / empty / truncated / non-object | refuse | **PASS** |
| duplicate field | refuse | **PASS** — not last-wins |
| missing field / unknown field | refuse | **PASS** |
| unsupported schema version | refuse | **PASS** |
| string uid / bool uid / uid 0 / negative uid | refuse | **PASS** |
| empty account | refuse | **PASS** |
| oversized body | refuse on bytes, before parsing | **PASS** |
| owned by coordinator | refuse | **PASS** — it could edit it |
| non-root group | refuse | **PASS** |
| group- or world-writable | refuse | **PASS** |
| directory / symlink | refuse | **PASS** |
| modes 0400, 0440, 0444 | accept | **PASS** |
| `sudoers_principal` from a look-alike mapping | refuse | **PASS** |

Plus the proof that no universal invariant survives: the string
`COORDINATOR_UID = 1000` is absent from the helper source, the policy module
exports no such constant, the action layer no longer reads one, and no
`KYRI_COORDINATOR_UID`-style environment escape exists. The policy module never
reads `os.environ` at all.

The two cases needing root ownership or a foreign uid supply a synthetic
`os.stat_result` rather than pretending an unprivileged suite can create one.
This is stated in the suite rather than glossed.

## 6. Helper and sudoers impact

### Bytes that change

| Source | Installed path | Old digest | New digest |
| --- | --- | --- | --- |
| `kyri-exec-transition.py` | `/usr/lib/kyri/python/kyri_exec_transition.py` | `44caf58f…` | `aba0d1f7…` |
| `kyri-exec-transition-action.py` | `/usr/lib/kyri/python/kyri_exec_transition_action.py` | `362c7d61…` | `201148ea…` |

`/usr/libexec/kyri-exec-transition` — the entrypoint, and the only thing sudo
names — is **unchanged**, and its installed bytes match repository source
exactly at `bd31bcbf…`. So the sudoers digest pin does not move.

### The drift, which predates this checkpoint

The installed library modules are **not** repository HEAD, and were not before
this work began:

```
installed  kyri_exec_transition.py        6488044b…
HEAD src   kyri-exec-transition.py        44caf58f…
```

Traced by replaying history: the installed bytes are commit
**`cfb0edd31b3589f12b6ba583ebfa48bb64e89519`**. Source has since advanced through
`16f285e` (*"prove the whole transition chain and stop before execution"*) and now
`f9d94ce` (this checkpoint).

So the helper ceremony must install **two accumulated changes**, not one. This is
install lag, not tampering: the entrypoint matches, the modules are exactly a
historical commit, and nothing changed during this checkpoint. It is recorded
because a ceremony written as "apply the coordinator change" would silently ship
`16f285e` as well.

**`PRIVILEGED_HELPER_CHANGE_REQUIRED = YES`**, and the ceremony is a separate
privileged authority surface from the runtime installer — the two library modules
live under `/usr/lib/kyri/python/` beside the generation tree but are not part of
it, and must not be bundled into a runtime install.

### The sudoers candidate

Authored, validated, **not installed**. `/etc/sudoers.d/kyri-exec` remains absent
and G3 stays closed.

```
Cmnd_Alias KYRI_EXEC_TRANSITION = \
    sha256:bd31bcbf63423a9e9e418a28c974233ecb73d0d67f4b54837f8bbed2b8d5c932 \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$

cschott ALL=(root) NOPASSWD: KYRI_EXEC_TRANSITION
Defaults!KYRI_EXEC_TRANSITION !requiretty, env_reset
```

`visudo -cf` → `parsed OK`. Candidate digest
`63e4fbb27a72419ecaa246ae14f5af73fd1b8a1a6e9523c75833c2bc183ccef1`.

Two things were checked rather than assumed, and one of them changed the file:

**The argument constraint is a real regex.** `visudo` parsing successfully would
*not* have proved that. Sudoers matches command arguments with shell globs by
default, under which `^CINV-[0-9]{6}$` would match nonsense. `man 5 sudoers` on
this host confirms: *"Command line arguments can include wildcards or be a
regular expression that starts with '^' and ends with '$'."* Regex arguments
need sudo ≥ 1.9.10 and digest pinning ≥ 1.9.0; this host runs **1.9.15p5**. The
form is load-bearing and the version supports it.

**`noexec` was removed after being written.** It would have broken the helper
outright — the helper's entire purpose is to `execve` the worker after dropping
privilege. Recorded because the mistake is an easy one and the grant looked
more restrictive with it.

The principal is `cschott`, derived by `sudoers_principal()` from the
coordinator authority candidate rather than typed in.

## 7. Ceremony candidates

Prepared and rehearsed. **Nothing was installed.**

### Coordinator authority

Derived from the live host (`pwd` entry for the running uid), not assumed:

```json
{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}
```

76 bytes with the trailing newline; SHA-256
`3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811`.

Rehearsed through the real `load_coordinator_authority` with the ownership facts
the ceremony will create (`root:root 0444`): accepted, uid `1000`, account
`cschott`, principal `cschott`.

Future root install block, for a checkpoint that is authorised to run it:

```bash
sudo install -o root -g root -m 0444 /dev/null /etc/kyri/coordinator-identity.json
printf '%s\n' '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}' \
  | sudo tee /etc/kyri/coordinator-identity.json >/dev/null
sudo sha256sum /etc/kyri/coordinator-identity.json   # expect 3dec888c…
```

**`COORDINATOR_AUTHORITY_CANDIDATE = READY`**, **`SUDOERS_CANDIDATE = READY`**,
**`PRIVILEGED_HELPER_CANDIDATE = READY`** (bytes and digests in §6; the ceremony
must carry both accumulated commits).

## 8. Why the backend is not here

### The blocker

The governed image is reachable only through privilege this checkpoint does not
hold:

| Fact | Observed |
| --- | --- |
| Podman | 4.9.3, present |
| Coordinator's own rootless store | empty; `/etc/subuid` `cschott:100000:65536` |
| `/data/kyri/capability` | `0750 kyri-capability`; `Permission denied` to the coordinator |
| `5cee2b53…` | present only in that store (G11-AE/AF) |

Every route to the bytes fails a rule:

- `podman save` as `kyri-capability` — needs `sudo`, and this checkpoint has no
  read-only authorisation covering it.
- Copying the storage tree — needs privilege, and Phase 22 forbids touching
  production storage.
- Rebuilding from the base — G11-AD proved reproduction impossible (the image ID
  is the config digest and the config embeds `created`), and Phase 9 forbids
  pulling.

### Why that stops Phases 7–19 too, and not just 20–22

Phases 7–19 are writable without the image: a closed backend registry, exact-ID
resolution against `overlay-images/images.json`, fixed-entrypoint argv, the
`--network none` pin, mount and environment policy, and a refusal matrix are all
testable against fixtures.

What is **not** available without the image is any evidence that the argv
actually runs, that the container starts under the intended uid mapping, that
the read-only rootfs permits the workload, that the output mount behaves, that
the lifecycle terminates cleanly — or that `interpreter_link`,
`interpreter_sha256` and `interpreter_target` match (Phase 21, which G11-AF left
open and Phase 11 requires closed *before* production execution).

Phase 17 requires that no failure produce ambiguous success, and the STOP
conditions name both *"exact 5cee image cannot be safely exercised in
isolation"* and *"lifecycle can leave ambiguous running state"*. Shipping a
privileged container-execution path whose only evidence is that its argv string
looks right would satisfy neither. I did not write it rather than write it
unverified.

### What a ruling would unblock

One of the following, at the reviewer's discretion:

1. **Authorise a read-only export.** `sudo runuser -u kyri-capability -- env
   HOME=/data/kyri/capability XDG_RUNTIME_DIR=/run/user/999 podman save
   --format oci-archive -o <path> 5cee2b53…` writes an archive **outside** the
   store and mutates no image, tag or metadata. The archive can then be loaded
   into an isolated `--root`/`--runroot` store for E2E. The loaded image ID must
   be re-verified after import, since G11-AF showed the manifest digest and the
   image ID are different objects.
2. **Authorise the E2E to run as `kyri-capability` against an isolated
   `--root`**, leaving production storage untouched but reading the governed
   image in place.
3. **Rule that the backend ships fixture-verified only**, with interpreter
   closure and E2E deferred to the first live G6 ceremony — which contradicts
   Phase 11 and should be an explicit decision, not a default.

Option 1 is the smallest and keeps production storage read-only. It is what I
would recommend.

## 9. Generation 13

**Not prepared**, and the reason is a dependency rather than time. Phase 23
requires the closure to include *"the governed backend"* and *"coordinator
authority reader if part of installed runtime"*. The backend does not exist, so
a closure computed now would be a Generation 13 that omits the thing it is being
cut for.

Two facts were established for whoever does cut it:

**The coordinator authority reader is not in the generation tree.** It lives in
`kyri_exec_transition.py` and `kyri_exec_transition_action.py`, installed at
`/usr/lib/kyri/python/` **beside** `tools/` but not within it. The installed
runtime is 70 `.py` objects: 66 under `tools/` plus four top-level helper
modules. So this checkpoint's change is a **privileged-helper ceremony, not a
generation** — which is also why it must not be folded into the runtime
installer.

**G11-AG's admission bound and G11-AC's route-head change remain outside the
installed closure.** `tools/fabric/admission.py` is still absent from
`/usr/lib/kyri/python/tools/fabric/`, confirmed directly against the live
install. `GEN13_INCLUDE_REQUIRED` stays **NO** for both.

`NEXT_GENERATION = 13`, `GEN13_PREINSTALL = NOT_READY`.

## 10. Future Fabric renewal sequence

Unchanged from G11-AF's ordering, with §6's drift folded in. Derived, not
written — no production record was created.

1. install `/etc/kyri/coordinator-identity.json` (§7)
2. install the privileged helper — **both** accumulated commits (§6)
3. build and install Generation 13, once the backend exists
4. verify live backend and `invoke --preflight` against the installed runtime
5. CADV-000004
6. CINST-000003, bounded by CADV-000004 (G11-AG enforces this at the write)
7. CROUTE-0003 superseding CROUTE-0002
8. CSEL-000002
9. install the narrow sudoers grant (§6)
10. `invoke --preflight`
11. first production invoke
12. post-execution evidence
13. close the sudoers grant if the architecture rules it temporary

Fabric renewal stays last, for the reason G11-AG gave: every renewed record
carries a finite window, and the current chain expired precisely because it was
written before the execution system was ready.

## 11. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 80/80 |
| `run-validation.sh` (full) | **PASS**, 105/105 |
| Invoke preflight | **PASS** (was red on arrival) |
| Coordinator authority (new) | **PASS**, 44 assertions |
| Helper policy, transition action, launch bridge, launch CLI | **PASS** |
| Fabric, Trust, G11-X, G11-Y, admission, route, selection suites | **PASS** (inside full) |
| ShellCheck, repository-wide | clean |
| pre-commit | all five hooks passed |
| GitHub workflows | §13 |

The new suite is registered in both `run-validation.sh` and
`.github/workflows/ci.yml`; `test-developer-experience.sh` enforces that pairing
and passes.

## 12. Production non-mutation

Identical before and after:

| Surface | Value |
| --- | --- |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Fabric store | 21 files, `bcb2559b…f15e` |
| CIMP-000001 | `ecb38d80…9991b` |
| CINST / CADV / CROUTE / CSEL | 2 / 3 / 2 / 1 |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf…`, unchanged |
| `/etc/sudoers.d` | `README` only — G3 closed |
| `/etc/kyri` | `drwx--x--x root root`, unchanged |
| Coordinator Podman store | 0 images, unchanged |
| `kyri-capability` Podman store | never opened this checkpoint |

No CADV, CINST, CROUTE, CSEL, CINV or CRES created. Nothing renewed, staged or
invoked. No container created or started. No image saved, loaded, built, pulled,
tagged or removed. No coordinator authority, helper, sudoers or generation
installed. No CIMP, Trust, Fabric or Evidence mutation.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.
`PRODUCTION_CHAIN_EXPIRED = YES`, deliberately and unrenewed.

## 13. Findings carried forward

1. **The privileged helper is two commits behind the repository** (§6), and was
   before this checkpoint. The ceremony must ship both.
2. **The image-access ruling** (§8) gates the backend, the E2E, the interpreter
   closure, and Generation 13.
3. `5cee2b53…` and `86762793…` are still absent from repository authority.
4. `g5-supply-chain.sh:149-151` still hardcodes the superseded 3.14.7 candidate.
5. The G5 test fixtures still describe the non-admissible image.
6. `README.md:1381-1386` documents 12 approval fields; `APPROVAL_FIELDS` has 14.
7. `io.buildah.version` is recoverable from the artefact but ungoverned.
8. The effective container environment is six variables, not four — which the
   backend's closed environment policy will have to state.

Still separate: `WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`, `SEMGREP_RULESET_POLICY=DYNAMIC`.

## 14. Next checkpoint

**A reviewer ruling on §8**, which is the whole of the remaining blocker. With
option 1 authorised, G11-AI is the governed Podman backend written RED-first
against a fixture store, then exercised end to end in an isolated
`--root`/`--runroot` store against the exported governed image — closing
`interpreter_link`, `interpreter_sha256` and `interpreter_target` in the same
pass. Generation 13 follows the backend, not the other way round.

Independently runnable now, if the reviewer prefers to proceed in parallel: the
coordinator authority and privileged helper ceremonies (§7, §6), neither of
which depends on the image question.
