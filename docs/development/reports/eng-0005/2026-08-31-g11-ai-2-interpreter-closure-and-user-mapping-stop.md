# ENG-0005 G11-AI.2 — export closed, interpreter closed, and a stop on the container user

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Amends:** `2026-08-31-g11-ai-g6-podman-backend.md`, `2026-08-31-g11-ai-1-export-identity-correction.md`
**Starting authority:** `31e8560`
**Implementation commits:** `2dbb80f`, `7814e6f`, `bae9e3e`

The operator's export succeeded. Three things closed behind it, and then the
backend work stopped on a contradiction it is not entitled to resolve.

**Closed.** Production-store non-mutation is now proven rather than partially
unknown. The archive imports into an isolated store with its identity exactly
intact. All three outstanding CIMP-000001 interpreter fields match, taking the
build-input matrix to **15/15**.

**Stopped.** The governed argv runs the workload as container uid **1000**. The
admitted image CIMP-000001 declares **65532:65532**. The T8 profile check
compares 1000 against 1000 and passes, so nothing in the runtime notices. And
under either uid the governed output directory is **not writable by the
workload**, which means no capability could return a result. Both were proven
by executing the real image, not by reading code.

Fixing that means deciding a uid and mapping model across `worker.py`,
`profile.py` and `snapshot.py`. The brief says *"do not rewrite the invocation
architecture"* and makes *"image user/mapping does not satisfy intended security
boundary"* an explicit stop. So I stopped.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`, carried forward
untouched.

---

## 1. The measurement artifact, resolved

The successful export reported `EXPORT_STORE_FOOTPRINT=PRESENT` against a store
that had not changed. Verified mechanically rather than accepted on
interpretation — with comment lines removed, every manifest is byte-identical:

| Comparison | Structure | Content |
| --- | --- | --- |
| M0 → M1 | identical | identical |
| M1 → M2 | identical | identical |
| M0 → M2 | identical | identical |
| **failed run M0 → corrected run M0** | **identical** | **identical** |

The cause was entirely the header each manifest wrote into its own body
(`# structural manifest: M1`), so M1 and M2 differed on that line and nothing
else. **MEASUREMENT_ARTIFACT**, fixed in `2dbb80f`: the label now names the file
and is printed as progress but never written into it, and `manifests_identical`
ignores comment lines on both sides so a reintroduced header still cannot
manufacture a difference. Pinned by three RED-first cases.

That last row closes the `UNKNOWN` carried from G11-AI.1: the failed ceremony's
two read-only Podman verbs changed nothing measurable, so
`FAILED_EXPORT_PRODUCTION_STORE_MUTATED = NO`.

**What "identical" covers, and what it does not.** The manifests measure
existence, type, mode, owner and size for all 5704 objects, plus SHA-256 content
for all 68 JSON metadata records. They do not capture mtime, and they do not
hash the 3697 non-JSON regular files — overwhelmingly content-addressed layer
payload, plus `db.sql` and the lock files. `db.sql` is unchanged at 233472 bytes
across every capture and both runs, but a same-size in-place rewrite would not be
detected. **Image, layer and container authority are proven unchanged;
byte-level equivalence of the sqlite database is not claimed.**

`PODMAN_INIT_FOOTPRINT` now gets its own reported verdict, and on this host it
is `NONE` — a stronger result than the benign database write I had anticipated,
and worth stating rather than assuming.

## 2. Phase 6 — isolated import

The archive loads into a disposable `--root`/`--runroot` under the coordinator's
own identity. Production storage is never opened; it remains unreadable to the
coordinator at `0750`.

```
Loaded image: sha256:5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
imported: 5cee2b53…f5190
governed: 5cee2b53…f5190
ISOLATED_IMAGE_ID=EXACT
```

It arrives **untagged** (`<none>:<none>`), which is correct and reinforces that
nothing can execute by tag. No tag was substituted or normalised.

Operational note for anyone reproducing this: Podman refuses a `--runroot`
longer than 50 characters, so the isolated store paths are short rather than
descriptive.

## 3. Phase 7 — interpreter closure

G11-AF left three build-input fields UNVERIFIABLE because they describe the
image's *filesystem* and `podman image inspect` reports configuration. All three
now match exactly:

| Field | Expected | Observed | |
| --- | --- | --- | --- |
| `interpreter_link` | `python3` | `python3` | **PASS** |
| `interpreter_target` | `/usr/bin/python3.14` | `/usr/bin/python3.14` | **PASS** |
| `interpreter_sha256` | `041b9331…0de0` | `041b9331…0de0` | **PASS** |

**CIMP-000001 build inputs: 15/15 MATCH, 0 UNVERIFIABLE, 0 MISMATCH.**

Container execution was permitted for this step and was not used. Mounting the
image filesystem answers the question completely and runs nothing from the
image, which is strictly less capable, so the stronger permission was left on
the table.

The probe is committed (`7814e6f`) with its expectations pinned in the harness —
it does not accept them from a caller or read them from the image under test.
Verified in both directions: it refuses a non-governed archive at the identity
gate, and refuses a missing one before that.

## 4. Phase 17 — the pull policy, which was missing

`--network none` isolates the container. It says nothing about Podman, which
resolves images on the host network *before any container exists*. The governed
argv named no pull policy, so the default `missing` applied: an absent image ID
would be read as a repository reference and fetched.

So an image that failed the store presence check could still have arrived from a
registry. `--pull=never` is now in the argv (`bae9e3e`), verified accepted by the
installed Podman 4.9.3 against the real image.

The existing test here was weaker than it looked. It asserted the token `pull`
was **absent** from the worker source — which a worker naming no policy at all
satisfies, while leaving the default in force. Avoiding a word is not the
property wanted. It now requires exactly one occurrence, and requires it to be
`--pull=never`.

## 5. Phases 12–14 — proven by execution

The governed flag set was exercised against the real image in the isolated
store. These are observations from the workload itself, not from inspecting
configuration:

| Property | Observed | |
| --- | --- | --- |
| `--pull=never` accepted, container created | 64-hex identity returned | **PASS** |
| network | `none` | **PASS** |
| container root filesystem writable | `false` | **PASS** |
| `/kyri/package` writable | `false` | **PASS** |
| `/tmp` writable | `true` — the governed tmpfs | **PASS** |
| interpreter actually used | `/usr/bin/python`, reporting 3.14.6 | **PASS** |
| `sys.argv` | `["/kyri/package/main.py"]` | **PASS** — argv vector, no shell |
| in-container uid/gid/euid | as requested, all three agree | **PASS** |
| **`/kyri/output` writable** | **`false`** | **FAIL — §6** |

Read-only rootfs is achievable with the governed workload and needs no
broadening: the only writable paths are the governed tmpfs and the output mount.

## 6. The stop

### 6a. The governed user contradicts the governed image

`tools/capability/execution/worker.py`:

```python
CONTAINER_UID = 1000
CONTAINER_GID = 1000
```

`tools/capability/execution/profile.py`:

```python
EXECUTION_UID = 1000
EXECUTION_GID = 1000
```

The argv therefore passes `--user 1000:1000`, which **overrides** the image's
own user. The admitted image CIMP-000001 declares `User=65532:65532`, confirmed
from the exact image in the isolated store.

Executed both ways against the real image:

| `--user` | in-container uid | result |
| --- | --- | --- |
| `65532:65532` (the image's) | 65532 | runs |
| `1000:1000` (the governed argv) | 1000 | runs |

Container uid 1000 does not exist in the image's passwd database; its user is
`nonroot` (65532).

**Nothing would catch this.** `verify_observed` compares
`profile.execution_uid` (1000) against the uid Podman reports (1000). They
agree, so T8 passes. The profile, the argv and the verification are mutually
consistent and collectively disagree with the image that was admitted.

This has the same shape as the `COORDINATOR_UID = 1000` defect G11-AH removed:
a compiled-in 1000 that was true of the earlier Track B alpine context and was
never revisited when the Chainguard image was admitted at G4/G5.

### 6b. The governed output path is not writable by the workload

Under **both** uids:

```
--user 65532:65532  →  out_uid=0  mode=0700  WRITE_DENIED
--user 1000:1000    →  out_uid=0  mode=0700  WRITE_DENIED
```

In rootless Podman the host owner maps to container uid 0, so an output
directory owned by the worker appears root-owned inside. `EXPECTED_MODES` sets
it `0o700` and `snapshot.py` performs no chown — deliberately, and the snapshot
suite pins that it calls no ownership primitive. So a `0700` directory owned by
container-uid-0 is unwritable by any non-zero container uid.

**No capability could write its result.** This is not a fixture artifact; it is
the governed mode and the governed mount meeting the governed user.

`U=true` on the bind makes the write succeed, and trades the failure rather than
removing it: Podman chowns the host directory to the mapped subuid (observed:
`165531`), after which the worker at uid 999 could not read the result back to
collect it.

### 6c. Why I did not fix it

Resolving this requires choosing a uid and mapping model and applying it across
`worker.py` (`CONTAINER_UID`), `profile.py` (`EXECUTION_UID` and what T8
verifies), and `snapshot.py` (output ownership and mode) — and possibly the
mount policy. Every one of those is governed by the first-adapter design.

The brief says *"do not rewrite the invocation architecture"*, and lists
*"image user/mapping does not satisfy intended security boundary"* as an
explicit stop condition. Both apply. A backend shipped on top of this would
either fail at the first real invoke or quietly depend on a mount option that
breaks collection.

**Options for the ruling**, with what each costs:

1. **Align the governed user to the image** — `CONTAINER_UID/GID = 65532`. Makes
   the argv agree with the admitted image and makes T8 meaningful. Does **not**
   by itself fix the output mount.
2. **Govern the output ownership** — have the snapshot create the output leaf
   owned by the mapped uid for the governed container user. Needs the snapshot
   to gain an ownership primitive it is currently pinned as not having.
3. **Govern the mount option** — `U=true` on the output bind only. Smallest argv
   change; requires solving collection, since the host directory ends up owned
   by a subuid the worker cannot read.
4. **Map the container user to the worker** — `--userns` mapping so container
   65532 is host 999. Keeps ownership readable by the worker; changes the
   namespace model and needs its own T8 verification.

I would recommend 1 and 2 together: they make the runtime agree with the image
that was actually admitted, and keep the writable surface exactly one governed
path. But this is a design ruling, not an implementation detail.

## 7. Phase 15 — the effective environment is nine, not six

G11-AF recorded six. Observed from inside the running container, the effective
environment is **nine**:

| Variable | Value | Source |
| --- | --- | --- |
| `PATH` | `/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin` | image `Config.Env` |
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` | image `Config.Env` |
| `LC_ALL` | `C.UTF-8` | adapter `--env` |
| `PYTHONDONTWRITEBYTECODE` | `1` | adapter `--env` |
| `PYTHONHASHSEED` | `0` | adapter `--env` |
| `PYTHONUTF8` | `1` | adapter `--env` |
| **`HOME`** | **`/home/nonroot`** | **Podman**, from the image user's passwd entry |
| **`HOSTNAME`** | **`trackb`** | **Podman**, from `--hostname` |
| **`container`** | **`podman`** | **Podman**, injected unconditionally |

The three in bold come from Podman itself and appear in neither the image
configuration nor the adapter's declared set, so no amount of reading either
would have found them. `HOME` is the notable one: it is derived from the
container user, so it changes if §6a is resolved by changing the uid — at
uid 1000, which has no passwd entry, `HOME` will differ.

A closed environment policy must account for all nine and cannot be written
until §6a is settled. `CLOSED_ENVIRONMENT` stays open, now with the actual set
in hand rather than an estimate.

## 8. Phases 8–11, 16, 18–22 — not reached

Phase 8 gates the backend on Phase 7, which passed, so the backend was started.
It stopped at §6 before any backend module was written. No
`kyri-exec-podman.py` exists, `kyri-exec-worker.py` still refuses with *"no
governed runtime backend is bound; container execution is gated at G6"*, and
that refusal remains correct.

One architectural finding for whoever resumes, derived from the codebase's own
rules rather than chosen: **the backend cannot live in
`tools/capability/execution/`.** `test-capability-execution-lifecycle.sh` states
`worker.py` is *"the first execution module allowed to name Podman. Naming it is
all that is permitted: no socket, no API, no remote URI, no subprocess"*, and
*"subprocess binding is NOT assigned to T12, so it is forbidden outright."* The
home for a process-executing backend is `provisioning/execution/`, beside
`kyri-exec-worker.py`, whose docstring already says the backend is gate G6 bound
to `/usr/bin/podman`.

## 9. Generation 13

Unchanged from G11-AI §12 and still `NOT_READY`. The closure computed from the
installed entry roots contains no container-execution backend module —
`adapter.py` is installed baseline but is not reachable from any entry root — so
a generation cut now would omit the thing it is being cut for. `worker.py` is
now also part of the pending delta, declared in the G5 preflight rather than
left as drift.

## 10. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 81/81 |
| `run-validation.sh` (full) | **PASS**, 106/106 |
| `test-capability-execution-image-export.sh` | **PASS**, 16/16 |
| `test-capability-execution-lifecycle.sh` | **PASS**, including the new pull-policy case |
| `test-capability-execution-g5-preflight.sh` | **PASS** after declaring the `worker.py` delta |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

The G5 preflight failure was the repository working as designed: an intentional
byte change to an installed runtime object must appear as a declaration rather
than as drift. Declared, not suppressed.

## 11. Production safety

No production mutation. The `kyri-capability` graphroot was never opened this
session — the coordinator is still refused at `0750`. All container work ran in
disposable isolated roots, and every container created there was removed; no
orphans remain.

Not installed: helper, sudoers, coordinator authority, Generation 13. Not
created: CADV, CINST, CROUTE, CSEL, CINV, CRES. Nothing staged, invoked or
renewed.

Both ceremony directories are preserved as evidence:

| Path | Contents |
| --- | --- |
| `/tmp/kyri-g11-ai-oci-3c9f2cfb9c03` | the failed run's M0 — the only pre-Podman baseline |
| `/tmp/kyri-g11-ai-oci-a999e0e2c2bd` | the successful export, archive `ec8213c9…`, M0/M1/M2 |

The archive is temporary test evidence, not promoted implementation authority.
`/tmp`'s 30-day sweep still applies to both.

## 12. Next

A ruling on §6. Options in §6c. With one chosen, the remaining phases run in
order: the backend in `provisioning/execution/`, the closed registry, exact-ID
enforcement, the lifecycle mapping, the isolated end-to-end, and the negative
matrix — all of which now have a proven-working container to build against.

Independently runnable and still not blocked by any of this: the coordinator
authority ceremony and the cumulative helper ceremony, in that order.
