# ENG-0005 G11-AI — authorised image export derived, helper delta reconstructed, backend still gated

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `bd30d65086b518cef900282d3fe16aa74abe9f88`
**Implementation commits:** `6a46037`, `45e3edf`

The reviewer authorised G11-AH's option 1 — export the governed image read-only
into an archive outside production storage. That ruling unblocks the backend,
but it does not remove the privilege boundary in front of it: **the export needs
root, and this checkpoint has no interactive sudo TTY.** `sudo -n true` returns
`a password is required`. So the export is derived, written down, and stopped
at, exactly as Phase 4 directs.

What that gates, and what it does not, is the whole shape of this checkpoint.

**Derived and ready (Phases 1–4).** The exact Podman semantics, the read-only
before-manifest, the export destination, and a reviewable ceremony script. One
operator command runs it.

**Blocked behind the operator (Phases 5–22).** Interpreter closure needs the
archive; Phase 8 gates the backend on Phase 7 passing. The backend is not
written, for the reason G11-AH gave and this checkpoint did not overturn: a
container-execution path across a privilege boundary, shipped green on argv
assertions alone, is the ambiguous success Phase 19 forbids.

**Done, because none of it needed the image (Phases 23–28).** The cumulative
helper delta is reconstructed, and it found something: **the installed runtime
carries half of `16f285e`, and the half it carries is defeated by the half it
does not.** §9 is the finding. The sudoers regex semantics are now pinned by
tests rather than by a man-page reading. The Generation-13 closure is computed
mechanically and comes out `NOT_READY` for a demonstrated reason.

Production mutation: **none**. The archive does not yet exist.

---

## 1. Starting authority

Reconstructed rather than assumed. Nothing was reset.

| Check | Observed |
| --- | --- |
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `bd30d65086b518cef900282d3fe16aa74abe9f88` |
| `origin/…` | identical to HEAD; upstream tracked, `0 0` divergence |
| Working tree | clean |
| G11-AH report `bd30d65` | is HEAD |
| G11-AH implementation `4a7fdf3`, `f9d94ce` | both ancestors of HEAD |
| GitHub workflows at HEAD | CI, ShellCheck, Semgrep, CodeQL, Trivy, Gitleaks — all **success** |

Local baseline on arrival, re-measured rather than inherited: quick **80/80**,
full **105/105**.

## 2. The export ruling, and the boundary that remains

The reviewer permitted exactly one production-adjacent operation:

> READ exact image `5cee…` from production rootless storage → WRITE one
> temporary OCI archive OUTSIDE the production storage → checksum/inspect
> archive → leave production storage byte/metadata-equivalent.

The governed store is `/data/kyri/capability`, mode `0750`, owned by
`kyri-capability` (uid 999). The coordinator is `cschott` (uid 1000) and is
refused at the directory:

```
ls: cannot open directory '/data/kyri/capability': Permission denied
```

Reaching the image therefore requires `runuser -u kyri-capability`, which
requires root. Root here is interactive-only. That is not a blocker to be
worked around — it is the boundary functioning — so this checkpoint derives the
operation and stops.

## 3. Phase 1 — the export command, derived from the host

**The format name was checked, not carried over.** G11-AH's proposal used
`--format oci-archive`; the brief warned against using that blindly. `podman
save --help` on this host:

```
--format string   Save image to oci-archive, oci-dir (directory with oci
                  manifest type), docker-archive, docker-dir (directory with
                  v2s2 manifest type) (default "docker-archive")
```

Podman **4.9.3** spells it `oci-archive`. The proposal happens to be right, and
is now right for a stated reason. Note the default is `docker-archive`, so the
flag is load-bearing rather than decorative.

**A lower-mutation route was looked for and does not exist.** `skopeo copy
containers-storage:… oci-archive:…` would read the store without initialising a
libpod database at all, which is strictly less footprint than `podman save`.
`skopeo` is not installed, and installing it is itself a production mutation
this checkpoint is not authorised to make. `podman save` is therefore the
minimal available operation, not merely the obvious one.

**The graphroot is derived from source, not guessed.**
`tools/capability/execution/image_store.py` compiles in
`GRAPHROOT_RELATIVE = (".local", "share", "containers", "storage")` and reads
`overlay-images/images.json`, with the reasoning stated there: *"a store
location taken from the environment is a store an attacker can aim."* With
`XDG_DATA_HOME` unset, the store is:

```
/data/kyri/capability/.local/share/containers/storage
```

**The source is the ID, never the tag.** `5cee…` carries the tag
`kyri-capability-execution:g5`, and the tag is recorded as corroboration only.
A tag is a mutable pointer; the thing under test is an identity.

### The identity risk that decides the format

A local image ID in containers-storage **is** the digest of the image config
blob. That makes the format choice a correctness question rather than a
preference:

- Stored manifest already **OCI** → `--format oci-archive` copies manifest and
  config verbatim → the config digest, and therefore the image ID, survives.
- Stored manifest **Docker v2s2** → an oci-archive save *converts* it,
  rewriting the config → the reloaded image carries a **different ID**, and
  Phase 6 would stop.

G11-AF recorded `ManifestType = application/vnd.oci.image.manifest.v1+json`, so
the round trip is safe. But a report is not a fact about the store right now, so
the ceremony **re-checks the manifest type and aborts before the save** rather
than discovering a mismatch after an import. G11-AF's own warning — that the
manifest digest and the image ID are different objects — is what makes this
worth checking twice.

## 4. Phase 2 — the production-store before manifest

The store is unreadable to the coordinator, so the before-manifest is
necessarily part of the privileged block. It is structured as **three**
captures, not two:

| Capture | Taken |
| --- | --- |
| **M0** | before any Podman process opens the store |
| **M1** | after read-only Podman inspection, before the save |
| **M2** | after the save |

The reason for three is the reason Phase 5 exists. Podman opening its own
database is a write, and it is not the export changing image authority. A single
before/after pair would have conflated the two and reported a benign
initialisation as a finding — or, worse, taught the reader to wave away a real
one. **M1 → M2 is the export's own footprint**, and that is the number Phase 5
turns on. M0 → M1 is reported separately and is expected to be non-empty.

Each capture is two files:

- **structural** — `find -printf '%y %#m %U:%G %10s %P'`, sorted: catches an
  object appearing, vanishing, or changing size, mode or owner.
- **content** — SHA-256 of every `.json` under 1 MiB: catches an authoritative
  record rewritten in place at the same size, which is what a tag or image-ID
  mutation looks like.

Layer blobs are deliberately not hashed. Content-addressed data cannot change
without changing the metadata that names it, so hashing gigabytes would cost
minutes to re-prove what the cheap manifest already proves. That is the
"ceremony theater" the brief warned against.

Podman-level state is captured either side of the save: full-ID image
inventory with tags, container inventory, and `podman image inspect` of the
governed image. Recorded explicitly: `5cee…` present, its tag, and the
historical `a3ef70ee…` (expected `<none>:<none>`, untagged, inert).

The manifest mechanism was rehearsed against the coordinator's **own** rootless
store before being proposed for the governed one, so the operator is not the
first person to run it.

## 5. Phase 3 — the export destination

```
/tmp/kyri-g11-ai-oci-3c9f2cfb9c03
```

Verified absent at derivation time; the ceremony refuses if it exists. It is
outside `/data/kyri/capability`, and the ceremony refuses any path under that
root or outside `/tmp`.

Created `install -d -o kyri-capability -g cschott -m 0750`: the execution
identity can write the archive, the coordinator can read it for the isolated
store work, and **production storage gains no new writer**. Neither the
repository nor the graphroot is chmod'd or chown'd, and `/opt/schott-platform`
is never the working directory of the execution identity — the ceremony `cd`s
to `/tmp` first.

**Retention caveat.** `/usr/lib/tmpfiles.d/tmp.conf` carries `D /tmp 1777 root
root 30d`. `/tmp` is on the root filesystem (57 GiB free), not tmpfs, so the
archive survives reboot — but it is subject to a 30-day age sweep. If the
reviewer elects to retain it as deployment evidence, `/tmp` is the wrong home
and it must be moved deliberately. This is flagged rather than pre-empted:
promoting it into governed storage is exactly what the brief forbids doing
merely because it was useful.

## 6. Phase 4 — the operator command

The ceremony is `provisioning/execution/g11-ai-image-export.sh`, committed at
`6a46037`, ShellCheck-clean, and reviewable as text before it is privilege. It
carries no executable bit, matching the existing rule for everything under
`provisioning/execution` — the interpreter is named explicitly so a script that
cannot be executed cannot be executed by the wrong one.

Two commands. The first needs no privilege and prints the derived facts:

```bash
bash /opt/schott-platform/provisioning/execution/g11-ai-image-export.sh --plan
```

The second is the authorised operation:

```bash
cd /tmp
sudo bash /opt/schott-platform/provisioning/execution/g11-ai-image-export.sh \
  --run /tmp/kyri-g11-ai-oci-3c9f2cfb9c03
```

The export it performs, stated in full because it is the part that touches
production:

```bash
runuser -u kyri-capability -- env -i \
  HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 \
  PATH=/usr/bin:/bin \
  podman save \
    --format oci-archive \
    -o /tmp/kyri-g11-ai-oci-3c9f2cfb9c03/cimp-000001-5cee2b53.oci-archive.tar \
    5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

`env -i` rather than `env`: the execution identity gets exactly the transition's
environment — `HOME`, `XDG_RUNTIME_DIR`, and a fixed `PATH` — with nothing
inherited from the operator's root shell.

The run then produces, without further instruction: archive SHA-256; `stat`;
`tar -tvf` structural listing; the archive's own `index.json`, manifest and
config digest; M2; and the after-inventory diffs.

**The four Podman verbs this ceremony can reach are `images`, `image inspect`,
`ps` and `save`.** Pull, build, load, import, tag, remove, prune and `run` are
absent from the script rather than merely unused, which is a property the
reviewer can check by grep.

### The identity proof needs no import

The archive's OCI manifest names its config blob by digest, and for a
containers-storage image that digest **is** the local image ID. The ceremony
extracts `index.json`, follows it to the manifest, reads
`.config.digest`, and requires:

```
config digest == 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

If they disagree it aborts, and no amount of loading the archive would have
fixed that. This settles Phase 6's identity question **before** anything is
imported anywhere.

### Anticipated benign footprint

Stated in advance so the operator can distinguish it from a finding. Rootless
Podman opens its own database read-write on any invocation; on this host the
coordinator's store uses the `sqlite` backend, and the governed store's backend
is not observable without privilege. Expected M0 → M1 changes are confined to
`libpod/` database objects and `*.lock` files. **Any change to
`overlay-images/images.json`, to tag association, or to the image inventory is
not benign**, and the ceremony reports the content manifest for exactly that
reason.

One failure mode worth naming: rootless Podman invoked through `runuser` with no
login session occasionally objects to `XDG_RUNTIME_DIR` ownership or a missing
session bus. `/run/user/999` exists and is `drwx------ kyri-capability`, so this
is expected to work; if it does not, the correct response is to report the error,
not to widen the environment.

## 7. Phases 5–7 — not run

`OCI_EXPORT = NOT_RUN`. The archive does not exist, so:

- **Phase 5** (production-store non-mutation proof) — `NOT_RUN`; the ceremony
  produces the evidence when the operator runs it.
- **Phase 6** (isolated OCI storage) — `NOT_RUN`. The plan is settled: a
  disposable `--root`/`--runroot` under the coordinator's own identity, which
  needs no privilege and never touches the governed store. `cschott` has
  `/etc/subuid` range `100000:65536`, so rootless isolation is available.
- **Phase 7** (interpreter closure) — `NOT_RUN`. `interpreter_link`,
  `interpreter_sha256` and `interpreter_target` remain **UNVERIFIABLE**, exactly
  as G11-AF left them.

## 8. Phases 8–22 — the backend, and why it is still not written

Phase 8 is explicit: *"Only after Phase 7 PASS, continue G11-AH's backend
work."* Phase 7 has not run, so Phase 8 has not started. `BACKEND_IMPLEMENTED =
NO`.

This is the brief's own ordering, not a reprise of G11-AH's judgement call, and
the reasoning behind that ordering held up on inspection. Phases 9–20 are
*writable* against fixtures — a closed registry, exact-ID resolution, fixed
argv, `--network none`, mount and environment policy, a refusal matrix. What
none of them can be is *verified*: that the argv runs, that the container starts
under the intended mapping, that a read-only rootfs permits the workload, that
the lifecycle terminates without an orphan. Phase 19 makes an ambiguous
lifecycle an explicit stop condition, and Phase 22's negative matrix is only
meaningful against a backend that can actually execute.

Writing it now would produce a green suite whose only evidence is that an argv
string looks correct. That is the failure the stop boundary names.

One input for whoever writes it, carried forward from G11-AF finding 8 and
unchanged here: **the effective container environment is six variables, not
four.** The image's `Config.Env` contributes `PATH` and
`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`, and Podman merges those with
the adapter's declared `PYTHONDONTWRITEBYTECODE=1`, `PYTHONHASHSEED=0`,
`PYTHONUTF8=1` and `PATH`. Phase 15's closed policy must account for each, and
`SSL_CERT_FILE` in particular is inert under `network=none` and live the moment
networking is ever granted.

## 9. Phase 23 — the cumulative helper delta, and a live defect

### The chain, reconstructed mechanically

Installed bytes were hashed and matched against history rather than trusted to
G11-AH's summary:

| Module | Installed | `16f285e` | HEAD (`f9d94ce`) |
| --- | --- | --- | --- |
| `kyri_exec_transition.py` | `6488044b…` | `44caf58f…` | `aba0d1f7…` |
| `kyri_exec_transition_action.py` | `bd32af5d…` | `362c7d61…` | `201148ea…` |
| `kyri-exec-transition` (entrypoint) | `bd31bcbf…` | `bd31bcbf…` | `bd31bcbf…` |

`git log cfb0edd..HEAD` over the three helper sources returns exactly two
commits: `16f285e` and `f9d94ce`. The installed library modules are byte-exact
`cfb0edd`. The entrypoint — the only thing sudo names — is unchanged across all
three, so **the sudoers digest pin does not move**.

One correction to G11-AH §6, because it changes what an operator would verify:
that table's "old digest" column listed `44caf58f…` and `362c7d61…`. Those are
the **`16f285e` source** digests, not the installed bytes. The installed bytes
are `6488044b…` and `bd32af5d…`.

### Delta A — `16f285e`, uninstalled since before G11-AH

1. `worker_argv(launch)` → `worker_argv(launch, *, worker_script)`. Required
   keyword, no default, and the target must be an absolute path under
   `/usr/libexec/`.
2. `perform_transition` passes `policy.worker_script` instead of the module's
   own `WORKER_SCRIPT` constant. **This changes which binary the privileged
   helper execs after dropping privilege.**

### Delta B — `f9d94ce`, G11-AH's coordinator work

3. `COORDINATOR_UID = 1000` removed; no constant remains to fall back to.
4. `COORDINATOR_AUTHORITY_PATH`, schema constants, `_ACCOUNT_CHARACTERS` added.
5. `CoordinatorAuthority` type plus `check_coordinator_authority_object`,
   `parse_coordinator_authority`, `load_coordinator_authority`,
   `sudoers_principal`.
6. `_read_member` and `_open_invocation` take `expected_uid` instead of reading
   `module.COORDINATOR_UID`.
7. New `coordinator_authority()` reader; `authenticate_launch` and
   `authenticate_profile_source` now read
   `/etc/kyri/coordinator-identity.json` on **every** call, with no cache.

### The finding: `16f285e` is installed in half

The verification surface from `16f285e` **is** installed and matches HEAD
byte-for-byte:

| Installed | Digest | HEAD source |
| --- | --- | --- |
| `/usr/lib/kyri/python/kyri_exec_verify.py` | `3d70707d…` | identical |
| `/usr/libexec/kyri-exec-verify` | `fad96924…` | identical |
| `/usr/libexec/kyri-exec-verify-worker.py` | `5a614ff7…` | identical |

The transition half of the same commit is not. The consequence is live:

- `/usr/libexec/kyri-exec-verify` builds a policy with
  `worker_script = /usr/libexec/kyri-exec-verify-worker.py` and explicitly
  refuses a policy naming the production worker.
- The installed `kyri_exec_transition_action.perform_transition` calls
  `module.worker_argv(launch)` — the `cfb0edd` signature — which returns the
  compiled-in `WORKER_SCRIPT = /usr/libexec/kyri-exec-worker.py`.

So on the installed runtime, the verification-only entrypoint would exec the
**production** worker. Its own guard is defeated by the older action module
sitting underneath it. This is the exact divergence `16f285e`'s comment
describes — *"was then ignored here in favour of this module's own constant"* —
and it is currently live because the commit went in in halves.

**Reachability, stated honestly.** `/etc/sudoers.d` contains only the
distribution `README`; G3 is closed and
`sudoers.d/kyri-exec-verify.example` is not installed. There is no sudo grant
for `kyri-exec-verify`, so it cannot be invoked across the privilege boundary
today — only by root directly. It is a latent privilege-scope defect, not an
open one.

It is load-bearing for ordering all the same: **the helper must be brought to
HEAD before any sudoers grant for the verification path is installed.**

### Ceremony consequences

`PRIVILEGED_HELPER_CHANGE_REQUIRED = YES`. The ceremony installs the **full
reviewed current helper** — both library modules at their HEAD digests — not an
incremental patch, and describing it as "install the coordinator identity
change" would silently ship Delta A and its fix for the split above.

**Ordering is now forced, not merely tidy.** Delta B makes
`/etc/kyri/coordinator-identity.json` a hard dependency of
`authenticate_launch`: install the helper before the authority file and every
transition fails closed. The reverse is harmless — the old helper ignores the
file. So coordinator authority **must** precede the helper.

The two modules live at `/usr/lib/kyri/python/` beside the generation tree but
are not part of it. This is a privileged-helper ceremony, not a generation, and
must not be folded into the runtime installer.

`PRIVILEGED_HELPER_CUMULATIVE_DELTA = PASS`. Nothing was installed.

## 10. Phase 24 — coordinator authority candidate, revalidated

G11-AH's candidate was re-run against **current HEAD** rather than carried
forward on its word:

```json
{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}
```

76 bytes with the trailing newline. SHA-256
`3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811` —
byte-identical to G11-AH.

Loaded through HEAD's real `load_coordinator_authority` with the ownership facts
the ceremony will create (`root:root`, `0444`, regular file): **accepted**, uid
`1000`, account `cschott`, `sudoers_principal` → `cschott`. `COORDINATOR_UID` is
confirmed absent from the module.

`COORDINATOR_AUTHORITY_CANDIDATE = READY`. Not written; `/etc/kyri` is
unchanged.

## 11. Phase 25 — the sudoers candidate, now pinned by tests

G11-AH established from `man 5 sudoers` that an argument beginning with `^` and
ending with `$` is read as a regular expression, that this needs sudo ≥ 1.9.10,
and that the host runs **1.9.15p5** (re-confirmed here). A man-page reading is
not a regression guard, so Phase 25's "pin with tests" is now satisfied by four
cases in `tests/test-capability-execution-provisioning.sh` (`45e3edf`).

| Case | What it pins |
| --- | --- |
| argument is anchored | the exact literal `^CINV-[0-9]{6}$`; a dropped anchor is a silent widening with no syntax error |
| glob interpretation denies everything | see below |
| regex and helper agree | the pattern and `validate_cinv` accept/refuse identically over a 15-identity corpus |
| no `noexec` | it would forbid the `execve` the helper exists to perform |

The second case is the one worth having. Under glob semantics `^`, `{6}` and `$`
are literal while `[0-9]` matches a single character, so the pattern describes
strings no well-formed CINV can be. Asserted with `fnmatch`: a sudo too old for
regex arguments **denies every invocation** rather than admitting a malformed
one. Misinterpretation costs availability, never authority — which is the
direction a privilege grant is allowed to fail in. That was previously assumed;
it is now proven.

The third case matters because defence in depth that disagrees with the thing it
defends is not depth. The grant's regex and the helper's independent validator
are now required to agree exactly.

The existing repository rule that **no test suite may validate sudoers as
policy** (no suite may contain `visudo`, or reference the installed path) is
untouched; all four cases are static and unprivileged.

The candidate grant is unchanged from G11-AH — principal `cschott` derived via
`sudoers_principal()`, entrypoint digest `bd31bcbf…` (which §9 confirms does not
move), candidate digest `63e4fbb2…`, `noexec` deliberately absent.

`SUDOERS_CANDIDATE = READY`. `/etc/sudoers.d/kyri-exec` remains absent and G3
stays closed.

## 12. Phases 26–27 — Generation 13, computed rather than listed

Computed with `tools/dev/runtime_closure.py` over `git archive HEAD`, using the
same six entry roots the Generation-12 installer declares
(`tools.capability.cli`, `tools.capability.execution.worker`, and the four
flattened helpers). No file was appended by hand.

**HEAD closure: 61 objects.** Against the installed runtime:

| | Count | Objects |
| --- | --- | --- |
| identical | 53 | — |
| **REPLACE** | 5 | `capability/cli.py`, `capability/coordinator.py`, `capability/evidence.py`, `capability/package_resolution.py`, `capability/store.py` |
| **CREATE** | 1 | `capability/rehearsal.py` |
| REPLACE, *not* generation | 2 | `kyri_exec_transition.py`, `kyri_exec_transition_action.py` |

The last row is §9's helper ceremony and is excluded from the generation, per
G11-AH's ruling that those modules sit beside the generation tree rather than
within it. **The Generation-13 runtime delta proper is 6 objects: 5 REPLACE and
1 CREATE.**

### Why it is still `NOT_READY`

The closure contains **no container-execution backend module at all**.
`tools/capability/execution/adapter.py` is installed as baseline from an earlier
generation but is not reachable from any entry root at HEAD — the worker does
not import it. Ten installed objects sit outside the current closure for the
same reason.

So a Generation 13 cut today would install a runtime whose closure cannot reach
a backend: precisely the "generation that omits the thing it is being cut for"
that G11-AH predicted, now demonstrated mechanically rather than argued. When
the Podman backend lands it enters the closure and the delta above changes.

Also confirmed mechanically, closing a G11-AH open item: **`tools/fabric/
admission.py` is neither installed nor in the closure**, so G11-AG's admission
bound and G11-AC's route-head change remain outside the installed runtime.
`GEN13_INCLUDE_REQUIRED` stays **NO** for both.

`NEXT_GENERATION = 13`. `GEN13_PREINSTALL = NOT_READY`. No installer was
prepared, because its content is not yet knowable.

## 13. Phase 28 — validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 80/80 |
| `run-validation.sh` (full) | **PASS**, 105/105 |
| `test-capability-execution-provisioning.sh` (extended) | **PASS**, including 4 new cases |
| ShellCheck, repository-wide | clean, including the new ceremony |
| pre-commit | all five hooks passed |
| GitHub workflows | CI, ShellCheck, Semgrep, CodeQL, Trivy, Gitleaks — **success** |

One thing the new ceremony script caught on the way in, worth recording because
it is a rule that exists for a reason: `provisioning/execution` asserts that
**nothing beneath it carries an executable bit** — those files are installed
`0444` and invoked by a named interpreter, so a script that cannot be executed
cannot be executed by the wrong one. The script was initially committed `+x`,
the existing suite failed, and the mode was corrected rather than the assertion
relaxed.

## 14. Production non-mutation

| Surface | State |
| --- | --- |
| `kyri-capability` Podman store | **never opened**; the coordinator is refused at `0750` |
| Governed image `5cee…` | untouched; no export has run |
| OCI archive | **does not exist** |
| Installed runtime | 70 objects, unchanged |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf…`, unchanged |
| `/usr/lib/kyri/python/` helper modules | unchanged (still `cfb0edd`) |
| `/etc/kyri` | unchanged; no coordinator authority written |
| `/etc/sudoers.d` | `README` only — G3 closed |
| Fabric / Trust / CIMP / Evidence | untouched |

No container created, started or run. No image saved, loaded, imported, built,
pulled, tagged, removed or pruned. No CADV, CINST, CROUTE, CSEL, CINV or CRES
created. Nothing renewed, staged or invoked. No coordinator authority, helper,
sudoers or generation installed.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`. The
production chain remains expired, deliberately and unrenewed.

## 15. Phase 29 — derived production deployment order

Not executed. Dependencies are stated because two of them are now forced rather
than conventional.

1. **Install `/etc/kyri/coordinator-identity.json`** (§10). *Must* precede the
   helper: §9's Delta B makes it a hard dependency of `authenticate_launch`, and
   the current helper ignores it, so this order is safe in one direction only.
2. **Install the full reviewed helper** — both modules, both accumulated
   commits (§9). Closes the split-`16f285e` defect. *Must* precede any
   verification-path sudoers grant.
3. Run the authorised export (§6) and complete Phases 5–7.
4. Implement and verify the governed Podman backend, Phases 8–22.
5. Cut and install **Generation 13**, whose closure is only knowable after (4).
6. Verify live runtime and `invoke --preflight` against the installed runtime.
7. `CADV-000004`.
8. `CINST-000003`, bounded by CADV-000004 (G11-AG enforces this at the write).
9. `CROUTE-0003`, superseding CROUTE-0002.
10. `CSEL-000002`.
11. Install the narrow sudoers grant (§11).
12. Production `invoke --preflight`.
13. First controlled production invoke.
14. Verify CINV/CRES and artefacts.
15. Close the sudoers grant if the architecture rules it temporary.

Fabric renewal stays late, for G11-AG's reason: every renewed record carries a
finite window, and the current chain expired precisely because it was written
before the execution system was ready.

## 16. Archive cleanup

Nothing to clean. The archive does not exist. When the operator creates it:

| Field | Value |
| --- | --- |
| Path | `/tmp/kyri-g11-ai-oci-3c9f2cfb9c03/cimp-000001-5cee2b53.oci-archive.tar` |
| Owner / mode | `kyri-capability:kyri-capability`, directory `0750` `kyri-capability:cschott` |
| SHA-256 | recorded by the ceremony into `archive.sha256` |
| Purpose | isolated-store backend and interpreter testing only |

It must not be promoted into governed production authority merely because it was
useful, and `/tmp`'s 30-day sweep (§5) means retention requires a deliberate
move, not neglect.

## 17. Findings carried forward

1. **`16f285e` is installed in half, and the installed verification entrypoint
   would exec the production worker** (§9). Latent, not reachable — no sudo
   grant exists. Fixed by the full helper ceremony, which must precede any
   verification-path grant.
2. The image export needs an operator; everything downstream of it is blocked
   (§6).
3. The Generation-13 closure carries no backend module (§12), so the generation
   cannot be cut yet.
4. G11-AH §6's "old digest" column named source, not installed, digests (§9).
5. `/tmp`'s 30-day sweep makes it unsuitable for retained evidence (§5).
6. The effective container environment is six variables, not four (§8).

Carried unchanged from G11-AH and not revisited here: `5cee…` and `86762793…`
absent from repository authority; `g5-supply-chain.sh:149-151` hardcoding the
superseded 3.14.7 candidate; G5 fixtures describing the non-admissible image;
`README.md:1381-1386` documenting 12 approval fields against `APPROVAL_FIELDS`'
14; `io.buildah.version` recoverable but ungoverned. Still separate:
`WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`, `SEMGREP_RULESET_POLICY=DYNAMIC`.

## 18. Next checkpoint

Run the §6 command. It produces the archive, the identity proof, and the
production-store non-mutation evidence in one pass. G11-AJ then takes Phases
6–22 in order: isolated store, interpreter closure, and only then the governed
backend written RED-first and exercised end to end against the exported image.

Independently runnable now, and neither depends on the image: the coordinator
authority ceremony (§10) and the cumulative helper ceremony (§9) — in that
order, for the reason §9 gives.
