# ENG-0005 G11-AK — the observation made observable, and G6 opened

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `5752fb6fabbfd4bbe0172d8fde7f01d1ba3bf5b3`
**Implementation commits:** `3a5ba14`, `d424e13`, `744e36a`

Both rulings are implemented, and **G6 opens**: there is a real governed Podman
backend, and it has driven the admitted image through the whole adapter
sequence.

**Ruled and done.** `profile_schema_version` is gone from the runtime
observation and untouched everywhere it can actually be enforced. `sockets` is
derived from the runtime's own mount sources by asking the filesystem, which is
what makes it capable of answering "socket".

**Built and proven.** The backend creates, inspects, starts and reads lifecycle
against `/usr/bin/podman` through a narrow subprocess boundary, bound by a
closed registry. Driven through the real adapter against the real 5cee2b53
image it produced `completed`, a T8 verification pass against what Podman
actually reported, and a trusted result carrying the workload's own document.
Nine failure cases assert their outcome class, including a governed timeout
that leaves no orphan.

**Not reached, and stated plainly.** The worker entrypoint does not yet bind
the backend, so the invoke front half (CINV/CRES → worker → backend) is not
joined and Generation 13's closure still cannot reach the execution path.
§12 and §15 say exactly what remains.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none.

---

## 1. The G11-AJ stop, and the rulings

G11-AJ stopped because two of `ObservedProfile`'s twenty-three fields could not
be filled from anything a runtime reports. A backend would have had to take
them from the expected profile, making T8 compare the profile with itself — the
same shape as the container-uid defect G11-AJ had just removed.

The rulings: remove `profile_schema_version` from the observation entirely, and
derive `sockets` from runtime-observable facts with no-follow file-type
authority. Neither may be populated from the expected profile.

## 2. Ruling 1 — `profile_schema_version`

Removed from `ObservedProfile` and from the comparison. Nothing else moved:

| Where it is still enforced | Unchanged |
| --- | --- |
| `parse_canonical_profile` refuses an unsupported version | yes |
| `ExecutionProfile.profile_schema_version` | yes |
| `ExecutionFingerprint.profile_schema_version` | yes |
| `worker.profile_from_descriptor` version check | yes |
| `verify_observed`'s `UnsupportedProfileSchema` guard | yes |

The guard at the top of `verify_observed` is the point worth keeping in view:
T8 still refuses to run against a schema it has no verifier for. What it no
longer does is *compare* a version it pretended to have observed.

No compatibility default was added. Every construction migrated explicitly —
the profile suite, the container-identity suite, and the lifecycle inspection
fixtures.

## 3. Ruling 2 — socket derivation

`observed_sockets` takes the runtime's reported mounts and asks the filesystem
what each source is. One parameter, and it is the runtime's own report: there
is no seam through which an expected value could arrive.

| Case | Behaviour |
| --- | --- |
| A: allowed regular-file and directory sources | `()` |
| B: a source that is a Unix socket | reported as a socket |
| C: an extra socket bind | reported; T8 refuses |
| D: expected profile says none, source is a socket | reported anyway |
| E: source replaced by a symlink after verification | **refused**, not followed |
| missing / unstatable source | **refused**, not "no sockets" |
| a device node | **refused** |
| `tmpfs` (no host object) | skipped, as the mount type implies |
| malformed or relative source | **refused** |

E is the one the ruling was written for. Following the link would report the
harmless directory it points at and derive "no socket" from a path nobody
authorised, so a symlinked source is refused outright — this is not the layer
that decides which paths were authorised.

Every uncertainty refuses rather than skipping. "I could not tell what that
was" must never be delivered as "there were no sockets", which is the same rule
`RootlessImageStore` applies to the image index.

**It lives in its own module.** `lifecycle.py` is held to a clock rule and an
ambient-authority rule; a socket check needs `stat`, so putting it there would
have meant widening a security backstop to fit one function. The function moved
into `mount_evidence.py` instead and brought its own backstop with it. The
fixtures had to become honest to match: mounts that were described abstractly
now name real objects, because a derivation that consults the filesystem cannot
be satisfied by a dictionary.

## 4. Backend architecture

`provisioning/execution/kyri-exec-podman.py`, installed as
`/usr/lib/kyri/python/kyri_exec_podman.py`.

**Where it lives was determined, not chosen.** `tools/capability/` is asserted
to reach no subprocess at all, and `lifecycle.py` — the first module allowed
even to *name* Podman — is held to *"naming it is all that is permitted: no
socket, no API, no remote URI, no subprocess"*. So the binding lives on the
installed side, beside `kyri-exec-worker.py`, whose docstring has said since G2
that the backend is gate G6 bound to `/usr/bin/podman`.

**It executes the argv it is given and composes none of it.** The governed
command line comes from `create_argv` over an authenticated snapshot. The one
seam is a storage location — `--root`/`--runroot`, absolute paths only — which
is what lets an isolated store be exercised without a second code path.
Production passes none.

## 5. The subprocess boundary

| Control | Enforcement |
| --- | --- |
| executable | `/usr/bin/podman`, absolute, never resolved through `PATH` |
| subcommands | closed set of seven; `pull`, `build`, `run`, `load`, `save`, `push`, `tag`, `exec`, `cp` refused before any process exists |
| shell | `shell=False`, pinned; no `/bin/sh` reachable |
| argv | vector only, every element type-checked |
| environment | closed to `HOME`, `PATH`, `XDG_RUNTIME_DIR` |
| stdin | `DEVNULL` |
| stdout | bounded at 4 MiB |
| stderr | captured, truncated into the refusal |
| timeout | always set; expiry is a refusal, never a silent success |
| errors | `PodmanBackendRefused`, deriving `OSError` so `lifecycle.create` converts it |

No `subprocess` object escapes: what comes back is text or a refusal.

**The environment is taken from the transition rather than compiled in.** The
production values are the default, but a backend that hardcoded them could only
ever run as one identity — and the seam that makes it testable is the same seam
`worker.ENVIRONMENT` already owns.

## 6. The closed registry

`python-podman-v1` → `PodmanBackend`, by dictionary lookup. Refused: any other
identity, including near-misses and case variants. There is no `import_module`,
no `__import__`, no entry point, no plugin directory, no configured module and
no operator-supplied executable — each asserted absent from the AST, and the
module's entire import set is `{__future__, json, subprocess, typing}`.

## 7. Podman inspection mapping

Translation, never substitution. Where Podman spells something differently the
name is translated; where Podman reports nothing the key is left out, arrives
as `None`, and fails.

| Observation | Source | Note |
| --- | --- | --- |
| `oci_image_id` | `.Image` | the immutable local id; `ImageName`/`ImageDigest` deliberately not read |
| `network` | `.HostConfig.NetworkMode` | |
| `read_only_rootfs` | `.HostConfig.ReadonlyRootfs` | Podman spells it with a lowercase `o` |
| `no_new_privileges` | `no-new-privileges` in `.HostConfig.SecurityOpt` | |
| `dropped_capabilities` | derived — see below | |
| `effective_capabilities` | `.BoundingCaps` | |
| resource limits | `.HostConfig.Memory`, `MemorySwap`, `CpuQuota`, `CpuPeriod`, `PidsLimit` | |
| `execution_uid/gid` | `.Config.User` | an echo; the maps are the evidence |
| `uid_map` / `gid_map` | `.HostConfig.IDMappings` | the kernel fact |
| `hostname` | `.Config.Hostname` | |
| `mounts` | `.Mounts` | |
| `devices` | `.HostConfig.Devices` | |
| tmpfs size/mode/options | parsed from `.HostConfig.Tmpfs` option string | |
| `sockets` | derived from `.Mounts` sources | §3 |
| `profile_schema_version` | **absent** | not a container property |

### The image identity

One known spelling difference is normalised: `images --no-trunc` prefixes the
algorithm, container inspect does not. Nothing else. A truncated id, an
uppercase one, a tag, a longer string containing the identity, or a different
algorithm all return `None` and therefore fail — they are not different
spellings of the identity, they are different things.

### The capability translation, which needed a control

The profile states the policy as the single word `ALL`; Podman states the same
fact as an eleven-name expansion. Normalising the expansion back to `ALL` would
be assuming the flag took effect, so it is done only when the evidence agrees.

The control was run both ways against the installed Podman:

| Container | `CapDrop` | `BoundingCaps` |
| --- | --- | --- |
| created **with** `--cap-drop ALL` | 11 names | key omitted |
| created **without** it | 0 | all eleven of this host's capabilities |

So a present, non-empty bounding set is positive evidence that capabilities
remain, and it fails. `ALL` is claimed only when the bounding set says nothing
remains; a partial drop reports the raw expansion and does not match.

## 8. Lifecycle

| Podman state | Reported | Outcome class |
| --- | --- | --- |
| `created`, never started | `created`, `started_at` absent | `adapter-error` |
| `running` | `running` | `interrupted` |
| `exited` 0, start proven | `exited`, exit 0 | `completed` |
| `exited` non-zero, start proven | `exited`, exit n | `provider-error` |
| exit present, start not proven | untrustworthy | `adapter-error` |
| governed wall timeout | — | `timeout` |
| missing / unreadable | refusal | `adapter-error` |

**The zero time is carried through as absence.** Podman renders a container
that never ran as `0001-01-01T00:00:00Z`, which is truthy and would otherwise
read as evidence of a start.

**`start` attaches.** A detached start plus a poll would leave a window in
which the lifecycle read describes a container that is still running;
attaching makes the call return when the workload has actually terminated. A
non-zero workload exit is not a backend failure — it is the result — so the
exit status is read from the container's own state rather than from the client.

**The two timeouts are ordered deliberately.** The governed wall timeout is 30s
and the backend's own guard is 60s, so the governed path fires first and a
timeout is classified as a timeout rather than surfacing as a backend refusal.

## 9. Output collection

Proven in §11: the result is written by the workload through the governed
output mount, the host directory's ownership and mode are unchanged (`0700`,
worker-owned), and T14 admitted a `TrustedResult` carrying the workload's own
document, its manifest, and a SHA-256 over the bytes.

Collection happens whatever the terminal state says, because a failed
execution's output is still evidence; **admission** is what the gate governs.
`may_collect_result` is true only for a proven zero exit, which is why the
non-zero and no-result cases both collected and neither was trusted.

## 10. Full invoke E2E — not reached

**The front half is not joined.** `kyri-exec-worker.py` still refuses with *"no
governed runtime backend is bound; container execution is gated at G6"*, and
that refusal is now out of date but not yet wrong to leave: binding it needs the
protocol session over descriptors 0/1/2, snapshot materialisation, and quota
ordering, none of which this checkpoint built.

So the chain invoke → G11-X → G11-Y → staging → CINV/CRES → worker → backend is
**not** exercised end to end. What is exercised is everything from the
authenticated snapshot onward, which is §11.

Stated rather than implied, because the handoff field for it must read
`NOT_RUN` and a reader should know exactly which half is missing.

## 11. Backend E2E, and the failure matrix

`provisioning/execution/g11-ak-backend-e2e.sh`, driving the real adapter with
the real backend against the admitted image. The only doubles are the
start-authority session and the clock — the two collaborators the adapter takes
precisely because they belong to the coordinator.

**Success:**

```
outcome class                completed
start proven                 True
result trusted               True
workload document            {'ok': True, 'value': 42}
host output owner preserved  (uid, gid) unchanged
output mode not widened      0o700
```

**Failures, each asserting its outcome class:**

| Case | Outcome | Start proven |
| --- | --- | --- |
| workload exits 42 | `provider-error` | True |
| workload writes no result | `completed`, no result admitted | True |
| governed image not the one present | `adapter-error` | False |
| start not authorised | `adapter-error` | False |
| extra ungoverned mount | `adapter-error` | False |
| **socket mounted into the container** | `adapter-error` | False |
| wrong identity mapping | `adapter-error` | False |
| governed wall timeout | `timeout` | False |

The socket row is ruling 2 working end to end: a real Unix socket was bound in,
the derivation reported it from the filesystem, and T8 refused.

The timeout row is the one that could have left ambiguity. It asserts more than
an outcome: the container is **proven stopped** through the governed
termination path, and no orphan remains afterwards. A client that stops waiting
has not stopped anything, and the backend says so rather than inventing a
terminal state.

`LIFECYCLE_UNAMBIGUOUS = YES`.

## 12. Preflight extension — not done

Phase 17 was not reached. `invoke --preflight` is unchanged and still correct
for what it covers; it does not yet report backend readiness. It depends on the
same worker binding as §10.

## 13. Helper coherence

`tests/test-capability-execution-helper-coherence.sh` pins the split defect as
a **property**, not a version.

The installed helper carries half of `16f285e`: the verification surface is
current, the transition modules are `cfb0edd`. The consequence is live —
`kyri-exec-verify` refuses a policy naming the production worker and then calls
a `perform_transition` that ignores `policy.worker_script` and execs the
production worker anyway. Its own guard is defeated by the older module beneath
it.

So the suite asserts the two halves **agree**: the argv builder requires
`worker_script` as a keyword with no default, and the exec site passes it from
the policy. A helper where one half was updated and the other was not is
detectable from the two halves alone, which is exactly the installed condition.

It also records that the entrypoint's own guard is not self-sufficient, so
nobody reads it as protection on its own, and names the six objects that must
move together.

The installed state is **reported, never enforced** — the suite must pass on a
machine with no installed runtime, and what is installed is a deployment fact
rather than a property of the source under review. On this host it reports
`kyri_exec_transition.py: BEHIND | kyri_exec_transition_action.py: BEHIND |
kyri_exec_verify.py: current`.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Nothing installed.

## 14. Generation 13

Computed with `tools/dev/runtime_closure.py` over `git archive HEAD` from the
six declared entry roots. Closure **61 objects**, 51 identical to installed.

| Operation | Count | Objects |
| --- | --- | --- |
| REPLACE (generation) | 7 | `capability/cli.py`, `coordinator.py`, `evidence.py`, `package_resolution.py`, `store.py`, `execution/profile.py`, `execution/worker.py` |
| CREATE (generation) | 1 | `capability/rehearsal.py` |
| REPLACE (helper ceremony, separate) | 2 | `kyri_exec_transition.py`, `kyri_exec_transition_action.py` |

**Generation-13 runtime delta: 8 objects.**

Still `NOT_READY`, and the reason is now precise and mechanical: **the backend
is not in the closure.** `kyri_exec_podman.py`, `mount_evidence.py`,
`lifecycle.py` and `adapter.py` are all unreachable from any entry root,
because `kyri-exec-worker.py` does not import the backend. The module exists
and is proven; nothing yet binds it at an entry point, so a generation cut now
would still ship a runtime whose closure cannot reach the execution path.

`GEN13_PREINSTALL = NOT_READY`. No installer was prepared, because its content
is not yet knowable — which is the same reason G11-AI and G11-AJ gave, and the
same one commit will fix.

## 15. What remains, in order

1. **Bind the backend in `kyri-exec-worker.py`.** Protocol session over
   descriptors, snapshot materialisation, quota ordering, adapter construction.
   One change, and it closes §10, §12 and §14 together.
2. Full invoke E2E through CINV/CRES (Phase 14–15).
3. Preflight backend readiness (Phase 17).
4. Generation-13 closure and installer, which becomes knowable after (1).

## 16. Candidates

**Coordinator authority** — revalidated against current source. Byte-identical,
digest `3dec888c…2811`, accepted through the real
`load_coordinator_authority` with the ownership facts the ceremony will create,
principal `cschott`. `READY`, not installed; `/etc/kyri` unchanged.

**Sudoers** — sudo `1.9.15p5` re-confirmed. The four regex-semantics cases from
G11-AI still pass: the argument is anchored so sudoers reads it as a regex, a
sudo too old for regex arguments would deny every CINV rather than admit a
malformed one, the pattern and `validate_cinv` agree over a corpus, and
`noexec` is absent. `READY`, not installed; `/etc/sudoers.d` holds only the
distribution `README`.

## 17. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 85/85 |
| `run-validation.sh` (full) | **PASS**, 110/110 |
| runtime observation (new) | **PASS**, 13 cases |
| Podman backend (new) | **PASS**, 15 cases |
| helper coherence (new) | **PASS**, 6 cases |
| backend E2E against the real image | **PASS**, success + 8 failure cases |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

Three suites added; both totals rose by three, re-measured rather than assumed.
Four changed runtime objects and one new one are declared in the G5 preflight
delta rather than left as drift.

One self-inflicted failure worth recording: a full run reported *"declared 109,
executed 110"* because I edited `run-validation.sh` while that run was in
flight, and bash reads scripts incrementally. Re-run cleanly afterwards.

## 18. Production non-mutation

No production Podman storage was opened; the coordinator remains refused at
`0750`. Every container ran in a disposable isolated root and every one was
removed.

Not installed: backend, helper, sudoers, coordinator authority, Generation 13.
Not created: CADV, CINST, CROUTE, CSEL, CINV, CRES. Nothing staged, invoked or
renewed. CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 19. Next deployment ceremony

Unchanged, and still gated behind helper coherence:

1. `/etc/kyri/coordinator-identity.json` — must precede the helper, because the
   new `authenticate_launch` depends on it and the old one ignores it.
2. The **full cumulative helper**, atomically across all six objects (§13).
3. Generation 13, once the backend is bound and in the closure (§14, §15).
4. Then the Fabric sequence: CADV, CINST bounded by it, CROUTE-0003,
   CSEL-000002, the narrow sudoers grant, preflight, and the first controlled
   invoke.
