# ENG-0005 G11-AJ — container identity bound to the admitted image, output mapping closed

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `530c2b5816d2fbe6329b3a83841dcbc8a45b1d70`
**Implementation commits:** `b51b053`, `73e4471`

The reviewer ruled option 1 + option 4. Both are implemented, and every property
the ruling asked for is proven by executing the real governed image rather than
by reading configuration.

**Closed.** The user namespace mapping does everything the ruling required
simultaneously: the workload runs as `65532:65532`, a worker-owned `0700`
output directory is writable from inside, the host directory's ownership and
mode are unchanged afterwards, and the result is owned by the worker and
readable by it. No chown, no `U=true`, no widened mode, no privilege.

**Corrected.** The container identity is now stated once and bound to the
admitted image's admission contract. T8 verifies the uid/gid **map** — a kernel
fact the request does not determine — rather than `Config.User`, which is an
echo and read `65532:65532` in every broken configuration tested.

**Closed.** The effective container environment is nine variables, enumerated
with their sources and classifications. A tenth now fails.

**Stopped, narrowly.** Phase 11's backend cannot be written correctly without
one more ruling: two of T8's twenty-three observed fields are **not observable
from Podman at all**, so a backend must either fabricate them — recreating the
defect this checkpoint just removed — or report absence and make verification
impossible. §11 sets it out with evidence.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`, carried forward.
Production mutation: none.

---

## 1. Starting authority

Reconstructed, not reset. HEAD = `origin` = `530c2b5`, working tree clean,
G11-AI.2's report an ancestor. Baseline quick **81/81**, full **106/106**.

## 2. The ruling

Option 1 (align the governed user to the image) plus option 4 (map the
container user to the worker). Option 2 not authorised; `U=true` prohibited.

The identities the architecture must keep apart, and now does:

| | uid | gid |
| --- | --- | --- |
| host execution identity (`kyri-capability`) | 999 | 987 |
| governed container identity (CIMP-000001 `User`) | 65532 | 65532 |

The invariant: **CIMP image user = profile `execution_uid/gid` = worker
`--user` = observed runtime identity**.

## 3. Phase 1 — the namespace mapping, proven

`podman run --help` and `man podman-run` on this host document
`--userns=keep-id` with `uid=UID` and `gid=GID` sub-options. Derived from the
installed 4.9.3, not assumed from the suggested spelling.

All eight required properties, simultaneously, against the real governed image
in an isolated store:

| # | Property | Observed |
| --- | --- | --- |
| 1 | outer identity is the worker equivalent | uid 1000 gid 1000 |
| 2 | workload runs as the governed identity | uid/gid/euid/egid all **65532** |
| 3 | worker-owned `0700` dir writable inside | appears `65532:65532` `0700`, **WRITE_OK** |
| 4 | files land host-owned and collectable | `1000:1000 0644`, read and hashed |
| 5 | no recursive host chown | dir `1000:1000:700` before **and** after |
| 6 | no `U=true` | absent |
| 7 | no root privilege | unprivileged throughout |
| 8 | no widened mode | `0700` before and after |

**The acting identity is uid 1000, not 999.** The coordinator cannot become
`kyri-capability` without privilege this checkpoint does not hold, so the
experiment models the worker with the invoking user. This is an equivalence,
not the production identity, and it is exact in the property that matters:
`keep-id` maps *the invoking user* to the chosen container id, so the mapping's
behaviour is independent of which unprivileged uid invokes it. In production
the same argv maps 999 → 65532 rather than 1000 → 65532.

## 4. Phase 2 — negative controls

One happy path proves nothing, so five failure modes were run against the same
image:

| Configuration | Workload | `/kyri/output` seen as | Write | Host ownership |
| --- | --- | --- | --- | --- |
| default mapping, `--user 65532` | 65532 | `0:0` | **DENIED** | unchanged |
| default mapping, `--user 1000` | 1000 | `0:0` | **DENIED** | unchanged |
| `U=true` | 65532 | `65532:65532` | OK | **CHANGED → 165531:165531** |
| `keep-id:uid=1000` (wrong uid) | 65532 | `1000:65532` | **DENIED** | unchanged |
| `keep-id:gid=1000` (wrong gid) | 65532 | `65532:1000` | **OK** | unchanged |
| **`keep-id:uid=65532,gid=65532`** | **65532** | **`65532:65532`** | **OK** | **unchanged** |

Two rows are load-bearing.

**`U=true` is rejected on evidence, not preference.** It writes successfully and
chowns the host directory to `165531` — a subordinate id the worker cannot read.
It trades a write failure for a collection failure, which is why the ruling
forbids it and why the argv must not reach for it later.

**The wrong-gid row does not fail closed.** It writes successfully, because a
`0700` directory owned by the right uid grants the owner rwx regardless of the
gid mapping. No write test can catch it. That is precisely why T8 must verify
the gid map independently, and it is the case §5 exists for.

## 5. Phase 7 — T8 now verifies something the request did not determine

The defect being replaced was not the number 1000. It was that every layer
agreed: profile said 1000, worker restated 1000, argv requested 1000, Podman
echoed 1000, T8 compared 1000 against 1000. The system checked itself.

`Config.User` cannot fix that, because it is the echo. Across all four
experiments it read `65532:65532` — including the unmapped run where the
workload could not write, and the wrong-gid run:

| Configuration | `Config.User` | `UidMap` | `GidMap` |
| --- | --- | --- | --- |
| correct | `65532:65532` | `…, 65532:0:1, …` | `…, 65532:0:1, …` |
| wrong gid | `65532:65532` | `…, 65532:0:1, …` | `…, **1000:0:1**, …` |
| wrong uid | `65532:65532` | `…, **1000:0:1**, …` | `…, 65532:0:1, …` |
| no mapping | `65532:65532` | **absent** | **absent** |

The discriminator is the entry `65532:0:1` — container id 65532 maps to host id
0, the invoking user, for a range of one. The kernel establishes it; the
request does not determine it. So `lifecycle.observe` now reports `UidMap` and
`GidMap`, `ObservedProfile` carries them, and `verify_observed` requires the
governed entry in **both** directions.

`profile.identity_mapping()` states the entry's form once, for the same reason
the uid is now stated once.

### The mutation matrix

| Case | Result |
| --- | --- |
| correctly mapped observation | **verifies** |
| observed uid differs from profile | **refused** |
| observed gid differs from profile | **refused** |
| correct `User`, **no** mapping | **refused** |
| mapping binds the wrong uid | **refused** |
| mapping binds the wrong gid | **refused** |
| mapping binds a **subordinate** id (`65532:165531:1`) | **refused** |

The last is the `U=true` shape: writable inside, uncollectable outside.

## 6. Phases 4–5 — where 65532 becomes authority

The brief required this be determined mechanically rather than by replacing one
magic constant with another. It was, and the answer is a **designed decision**,
not an oversight.

`tools/provisioning/provisioning_evidence.py` defines a closed 15-field
`EVIDENCE_FIELDS` schema. **No image-user field exists** in it, and none exists
anywhere in the implementation-authority records.

`provisioning/execution/g5-ceremony.sh:146-150` says why, in terms:

> The schema is **NOT** extended. The image's default user, entrypoint, command
> and working directory are deliberately not evidence fields: §27 rules the
> image's own user "metadata", because T12 launches with an explicit `--user`
> and the profile verification compares what Podman reported. They are checked
> below as an image **CONTRACT**, never stored as authority.

and enforces it at admission: `IMAGE_EXPECT_USER="65532:65532"`.

So **option A**: fixed first-adapter policy legitimately binds the identity, and
the G5 contract is the admission-time check that the image agrees. Option B
would require changing the evidence schema and re-admitting CIMP-000001, which
the brief forbids and which §27 already decided against. **No CIMP change was
made and none is needed.** `CONTAINER_IDENTITY_AUTHORITY = ADAPTER_BOUND`, with
the admission contract as its counterpart.

The reasoning was sound; the wiring was missing. The contract said 65532 and the
adapter constant said 1000, and **nothing compared them**. So:

- `profile.EXECUTION_UID/GID` is the single statement, now `65532`.
- `worker.CONTAINER_UID/GID` **aliases** it rather than restating the number.
- A test holds `IMAGE_EXPECT_USER` and `EXECUTION_UID:EXECUTION_GID` equal, so
  the admission contract and the runtime policy cannot drift apart again.
- Another test forbids the worker restating the literal.

That is what makes this different from replacing 1000 with 65532: the
possibility of drift is removed, not relocated. Two constants that happen to be
equal today are the mechanism that produced the defect.

## 7. Phase 6 — the argv

Produced by `create_argv`, not transcribed:

```
podman create --name kyri-CINV-000042 --network none --pull=never
  --read-only --read-only-tmpfs=false --cap-drop ALL
  --security-opt no-new-privileges --pids-limit 64
  --memory 256m --memory-swap 256m --cpus 0.5 --hostname trackb
  --user 65532:65532 --userns keep-id:uid=65532,gid=65532
  --tmpfs /tmp:size=16m,mode=1777,noexec,nosuid,nodev
  --env LC_ALL=C.UTF-8 --env PYTHONDONTWRITEBYTECODE=1
  --env PYTHONHASHSEED=0 --env PYTHONUTF8=1
  --mount type=bind,src=…/pkg,dst=/kyri/package,ro=true
  --mount type=bind,src=…/payload,dst=/run/kyri/input/payload,ro=true
  --mount type=bind,src=…/out,dst=/kyri/output,ro=false
  5cee2b53…f5190 /usr/bin/python /kyri/package/main.py
```

Argv vector, no shell, no `U=true`, output mode unweakened.

## 8. Phase 8 — the output round trip

Host properties preserved exactly as the ruling required — the host directory is
worker-owned `0700` before and after, and nothing chowns anything:

```
HOST BEFORE   out dir: uid=1000 gid=1000 mode=700
CONTAINER     uid=65532 gid=65532  /kyri/output seen as 65532:65532 0700  WRITE_OK
HOST AFTER    out dir: uid=1000 gid=1000 mode=700   (unchanged)
              result : uid=1000 gid=1000 mode=644 size=594
              worker sha256: 88fcf93a…67e4
```

`OUTPUT_CHOWN_REQUIRED = NO`. The worker can stat, read and hash the result with
no privileged ownership-recovery step.

## 9. Phase 9 — quota

Unaffected, and the mechanism is why. `kyri-exec-quota` sets a **project ID** on
the host directory through `FS_IOC_FSSETXATTR`; XFS project quota binds to the
inode and its project, with inheritance, and is **independent of uid**. The
mapping provably does not change host ownership, and files written from inside
land host-owned by the worker inside the same project tree — so every input the
quota depends on is unchanged. `/data` is mounted `prjquota`.

The ordering (quota → descriptors → groups → gid → uid → permanent drop →
`no_new_privs` → exec) is untouched: it governs the **host worker's** privilege
drop, which the container mapping does not participate in.

Reasoned from the mechanism plus the observed ownership preservation. Not
demonstrated on `/data` itself, which would require production paths this
checkpoint must not touch.

## 10. Phase 10 — the closed environment

`worker.py` claimed the container environment was *"inherited from nothing — not
the host process, not the payload, not the package, not the protocol"*. That
described what the adapter **contributes**, not what the workload **sees**, and
it survived to G11-AF because nothing had ever read a running container's
environment. The claim is removed.

Nine variables, observed from the governed image under the governed argv:

| Variable | Value | Source | Class |
| --- | --- | --- | --- |
| `HOME` | `/home/nonroot` | **RUNTIME** | GOVERNED |
| `HOSTNAME` | `trackb` | **RUNTIME** | GOVERNED |
| `LC_ALL` | `C.UTF-8` | ADAPTER | REQUIRED |
| `PATH` | `/usr/local/sbin:…:/bin` | IMAGE | GOVERNED |
| `PYTHONDONTWRITEBYTECODE` | `1` | ADAPTER | REQUIRED |
| `PYTHONHASHSEED` | `0` | ADAPTER | REQUIRED |
| `PYTHONUTF8` | `1` | ADAPTER | REQUIRED |
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` | IMAGE | GOVERNED |
| `container` | `podman` | **RUNTIME** | GOVERNED |

The three RUNTIME variables appear in neither the image config nor this module,
so no amount of reading either would have found them. `HOME` is the notable
one: it derives from the container user's passwd entry, so it is a **function of
the governed identity** and would have changed silently had the identity been
corrected without observing the result.

Nothing is MUST-REMOVE or MUST-OVERRIDE. `SSL_CERT_FILE` is the one to watch —
inert only because the network is none, live the moment networking is granted.

Declared in `CONTAINER_EFFECTIVE_ENVIRONMENT`, and closed: the probe requires
declared and observed to match exactly, so a tenth variable from an image
rebuild or a Podman upgrade fails rather than being absorbed.
`CLOSED_ENVIRONMENT = PASS`.

## 11. Phase 11 — the backend, and the ruling it needs

Everything the backend must *produce* is now proven: exact image ID,
`--pull=never`, network none, read-only rootfs, fixed interpreter, read-only
package mount, output-only writable mount, closed environment, `cap-drop ALL`,
`no-new-privileges`, resource limits, argv-vector execution with no shell. All
verified against the real image in §12.

What is missing is the module that *drives* the process, and writing it
correctly needs one decision.

**Where it must live** was determined from the codebase's own rules, not
chosen. `test-capability-execution-lifecycle.sh` states `worker.py` is *"the
first execution module allowed to name Podman. Naming it is all that is
permitted: no socket, no API, no remote URI, no subprocess"*, and
*"subprocess binding is NOT assigned to T12, so it is forbidden outright."*
So the backend belongs in `provisioning/execution/`, beside
`kyri-exec-worker.py`, whose docstring already says the backend is gate G6 bound
to `/usr/bin/podman`.

**The blocker.** `ObservedProfile` has 23 fields, and the backend must supply
them from `podman inspect`. Most are directly observable. Two are not:

| Field | Podman reports |
| --- | --- |
| `profile_schema_version` | **nothing — not a container property** |
| `sockets` | **nothing — not a Podman field** |

and two need translation rather than transcription:

| Field | Podman reports | Profile expects |
| --- | --- | --- |
| `dropped_capabilities` | the expanded list (`CAP_CHOWN`, `CAP_DAC_OVERRIDE`, …) | `("ALL",)` |
| `effective_capabilities` | absent from `inspect` output | `()` |

A backend that supplies `profile_schema_version` can only get it from the
profile — at which point T8 compares the profile against itself, which is
**exactly the defect this checkpoint removed**, in a new place. A backend that
reports `None` fails verification permanently, since `None` always fails, and no
execution could ever succeed.

Neither is improvisable: both change what T8's verification contract *means*.
Options, smallest first:

1. **Drop the two unobservable fields from `ObservedProfile`.** They cannot be
   evidence, so verifying them is theatre. Narrows T8 to what a runtime can
   actually attest.
2. **Keep them, verified elsewhere.** `profile_schema_version` is already
   checked against `PROFILE_SCHEMA_VERSION` at the top of `verify_observed`;
   `sockets` could be derived from `Mounts` (no socket bind present) which
   *is* observable.
3. **Have the backend attest them explicitly** as backend-asserted rather than
   runtime-observed, so the distinction is visible in the type.

I would recommend 1 for `profile_schema_version` and 2 for `sockets` — the
first is not a property of a container at all, the second genuinely is
observable once derived from the mount list. But that is a change to the
governed verification contract, and the brief says not to rewrite the invocation
architecture.

`BACKEND_IMPLEMENTED = NO`. `kyri-exec-worker.py` still refuses with *"no
governed runtime backend is bound; container execution is gated at G6"*, which
remains correct.

## 12. Phase 12 — isolated end-to-end

`provisioning/execution/g11-aj-e2e-probe.sh`, harness-owned. It executes the
argv `create_argv` produces, with only `--root`/`--runroot` spliced in for
isolation — typing the flags out would test the probe's idea of the contract
rather than the contract, which is how a `--user` disagreeing with the admitted
image went unnoticed for all of Track B.

```
isolated image id          PASS  5cee2b53…f5190
Config.User                PASS  65532:65532
image                      PASS  5cee2b53…f5190
uid map                    PASS  contains 65532:0:1
gid map                    PASS  contains 65532:0:1
terminal state             PASS  exited:0
output dir unchanged       PASS  1000:1000:700
result owned by worker     PASS  1000:1000
workload uid               PASS  65532
workload gid               PASS  65532
interpreter                PASS  '/usr/bin/python'
argv                       PASS  ['/kyri/package/main.py']
working directory          PASS  '/'
output visible as governed PASS  65532
output mode not widened    PASS  '0o700'
package read-only          PASS  False
rootfs read-only           PASS  False
governed tmpfs writable    PASS  True
environment size           PASS  9
undeclared variables       PASS  []
declared but absent        PASS  []
containers remaining       PASS  0
```

**`ISOLATED_E2E = PASS`** for the half this checkpoint governs: snapshot →
Podman → container → workload → governed output → worker collection → lifecycle
→ cleanup, no orphan.

The front half of Phase 12 — fixture invoke → authority → CINV/CRES → staging —
is **not** exercised here. It needs a fixture Fabric and Trust harness and,
more to the point, it needs the backend of §11 to bind the two halves together.
Stated plainly rather than implied by the PASS above.

## 13. Phase 13 — the helper split

Unchanged and untouched. The installed helper is still `cfb0edd`-era; nothing in
this checkpoint modified it, and no sudoers or helper was installed. The
ceremony must still move the installed helper to the full current reviewed
helper in one step, carrying the previously uninstalled `16f285e` change, the
coordinator-authority change, and anything since — not presented as one
incremental patch.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`.

## 14. Phase 14 — Generation 13

Computed with `tools/dev/runtime_closure.py` over `git archive HEAD` from the
six declared entry roots. Closure: **61 objects**, 51 identical to installed.

| Operation | Count | Objects |
| --- | --- | --- |
| REPLACE (generation) | 7 | `capability/cli.py`, `coordinator.py`, `evidence.py`, `package_resolution.py`, `store.py`, `execution/profile.py`, `execution/worker.py` |
| CREATE (generation) | 1 | `capability/rehearsal.py` |
| REPLACE (helper ceremony, **not** generation) | 2 | `kyri_exec_transition.py`, `kyri_exec_transition_action.py` |

**Generation-13 runtime delta: 8 objects.**

Still `NOT_READY`, and now for a precisely stated reason. `lifecycle.py` — which
this checkpoint changed, and which is declared in the G5 preflight delta — is
**installed but outside the closure**, along with `adapter.py`, `collector.py`
and the rest of the execution chain. Nothing imports them from any entry root,
because nothing binds a backend. A generation cut now would still ship a runtime
whose closure cannot reach the execution path. `GEN13_PREINSTALL = NOT_READY`.

## 15. Phase 15 — validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 82/82 |
| `run-validation.sh` (full) | **PASS**, 107/107 |
| `test-capability-execution-container-identity.sh` (new) | **PASS**, 14 cases |
| `test-capability-execution-lifecycle.sh` | **PASS** |
| `test-capability-execution-profile.sh` | **PASS** |
| `test-capability-authority-resolution.sh` | **PASS** |
| `test-capability-execution-g5-preflight.sh` | **PASS** after declaring the delta |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

Totals rose by one in both modes: the new suite runs in both, re-measured
rather than assumed. Three changed runtime objects — `profile.py`, `worker.py`,
`lifecycle.py` — are declared in the G5 preflight generation delta rather than
left as drift.

One assertion was tightened rather than deleted:
`test-capability-authority-resolution.sh` asserted `execution_uid == 1000` as a
literal. A literal is how the identity drifted in the first place — the number
was restated in enough places that changing the policy did not change the
assertions — so it now asserts against the governed constant.

## 16. Production non-mutation

No production Podman storage was opened; the coordinator remains refused at
`0750` on `/data/kyri/capability`. Every container ran in a disposable isolated
root and every one was removed — `containers remaining: 0`.

Not installed: helper, sudoers, coordinator authority, Generation 13. Not
created: CADV, CINST, CROUTE, CSEL, CINV, CRES. Nothing staged, invoked or
renewed. CIMP-000001 unchanged and immutable.

Preserved as evidence:

| Path | Contents |
| --- | --- |
| `/tmp/kyri-g11-ai-oci-3c9f2cfb9c03` | failed run's M0 baseline |
| `/tmp/kyri-g11-ai-oci-a999e0e2c2bd` | the export, archive `ec8213c9…` |

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 17. Next deployment gate

Nothing installable has changed. The gate remains the helper ceremony, and the
ordering from G11-AI stands: coordinator authority first (the new
`authenticate_launch` depends on it, the old one ignores it), then the full
cumulative helper, then Generation 13 once the backend exists.

The immediate next decision is §11: the two `ObservedProfile` fields Podman
cannot report. With that ruled, the backend is a bounded piece of work — every
flag, mapping and environment value it must produce is now proven against the
real image.
