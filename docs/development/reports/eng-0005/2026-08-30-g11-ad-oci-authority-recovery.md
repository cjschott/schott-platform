# ENG-0005 G11-AD — OCI image authority recovery and re-admission design

**Date:** 2026-08-30
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `2a4031ec71a109032028b0e8f6345e6734a35055`
**Implementation commit:** none — forensic audit

Two findings change the picture G11-AB left.

**Exact reproduction is impossible by construction, not by missing inputs.** The
governed image identity is a Podman *local image ID*, which is the image config
digest, and the config embeds a build timestamp. Two builds from byte-identical
inputs seconds apart produce different IDs. Proved empirically in isolated
storage. Option B is closed.

**The exact artefact has never actually been searched for.** G11-AB reported the
image absent after reading the *coordinator's* Podman store. The governed
procedure loads it into the **`kyri-capability`** rootless store, which is
`0750 kyri-capability` and which the coordinator account cannot read. Likewise
the provisioning evidence that would resolve `86762793…` lives at
`/root/kyri-g5-provisioning-evidence.json`, root-owned `0400` by design. Neither
was read. **That correction is mine to make, and I make it here.**

So `OCI_RECOVERY = UNRESOLVED`, not `NOT_RECOVERABLE`, pending two read-only
operator commands. Choosing option C now would be premature.

CIMP-000001 was not modified.

---

## 1. Starting authority

Verified at `2026-08-30T12:18:10-05:00`; the chain had 4h 1m of validity left and
is being allowed to expire.

| Check | Observed |
| --- | --- |
| HEAD / origin | `2a4031ec…`, clean, synchronized |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Fabric store | `bcb2559b…f15e` |
| Routes | CROUTE-0001, CROUTE-0002; sequence 2 |

## 2. CIMP-000001, reconstructed

The record, verbatim, and internally consistent — its SHA-256 is `ecb38d80…`,
which is exactly the `admission` digest the CGEN-000000000001 authority set
carries:

```json
{"adapter_identity":"python-podman-v1","argv_contract_identity":"fixed-python-entrypoint-v1",
 "cimp":"CIMP-000001","execution_profile_schema_version":2,
 "oci_image_id":"5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190",
 "payload_schema_version":1,
 "provisioning_evidence_digest":"86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac"}
```

No retirement is published; the entry reads `"retirement": null`. Written
`2026-08-14 15:37`.

### What the digest actually is

The field is `oci_image_id`, and that wording is load-bearing.
`RootlessImageStore._identities()` reads the **`id` field** of each entry in
`overlay-images/images.json` and requires bare 64-hex, refusing anything else —
*"Names, tags, digests and history are deliberately ignored."* The ceremony
obtains it with `podman image inspect --format '{{.Id}}'`.

So `5cee2b53…` is a **containers/storage local image ID**, which for Podman is
the **image config blob digest**. It is *not* a manifest digest, not an image
index digest, and not an archive digest. Anything compared against it must be
the same kind of object.

## 3. The provisioning evidence — not missing, unread

`86762793…` is the SHA-256 of the ruled post-build record. `g5-ceremony.sh:151`
declares where it lives:

```
PRODUCTION_EVIDENCE="/root/kyri-g5-provisioning-evidence.json"
```

verified by the ceremony as `root:root 0400`, and described as *"outside
anything the coordinator can reach."* Its fifteen closed fields are the entire
build authority:

`architecture`, `base_image_reference`, `containerfile_sha256`,
`evidence_schema_version`, `interpreter_link`, `interpreter_path`,
`interpreter_sha256`, `interpreter_target`, `oci_image_id`, `os`,
`python_version`, `sbom_python_package`, `sbom_python_version`, `sbom_sha256`,
`source_commit`.

G11-AB searched the repository and the readable host and concluded it "resolves
to nothing". That conclusion was drawn over a search space that excluded, by
design, the only place the file is allowed to be. **The evidence is very
probably present and simply unread.**

## 4. Repository history

Exhaustive: every blob reachable from every ref, plus unreachable objects via
`git fsck --lost-found` — 4,862 objects scanned for each identifier.

| Identifier | Found in git history |
| --- | --- |
| `5cee2b53…` | **Only** in `g11-aa` and `g11-ab`, reports I wrote |
| `86762793…` | **Only** in `g11-ab` |
| `a3ef70ee…` | `tests/test-capability-execution-g5-authority.sh`, and my `g11-ab` report |

So neither the admitted image ID nor its evidence digest has ever been committed
to the repository. That is consistent with the design — the README says
*"Nothing in this repository builds, pulls, loads, or admits this image"* — and
is not itself evidence of loss.

### Timeline

| When | What |
| --- | --- |
| 2026-08-12 09:10 | `provisioning/image/Containerfile` authored |
| 2026-08-14 13:25 | `/data/kyri/capability` last modified — the build/load window |
| 2026-08-14 15:37 | **CIMP-000001 admitted**, naming `5cee2b53…` |
| 2026-08-14 18:46 | commit `c2e0bed` records `a3ef70ee…` as *"the live facts this pass was given"* |

Both identities are from the same day, roughly three hours apart, and CIMP came
first.

## 5. Local artefact search

Scoped to Kyri and container locations, read-only.

| Location | Result |
| --- | --- |
| Coordinator graphroot `~/.local/share/containers/storage` | no `overlay-images/images.json`; `podman images` empty |
| `/var/lib/containers/storage` | absent |
| `/data/kyri/capability` | **`0750 kyri-capability`, 6 entries, mtime 2026-08-14 13:25 — unreadable to the coordinator** |
| OCI-shaped archives in scope | one hit, `backups/schott-platform-config-20260812-175245.tar.gz` |

That archive is a 164-file configuration backup from 2026-08-12, two days before
the build, containing no container storage. Listed, not extracted; not a
candidate.

**The store the image was loaded into is the one that was never searched.** The
README's admission procedure step 1 is *"loads the built image into the
`kyri-capability` rootless store"*, and `g5-ceremony.sh` drives every Podman
call as `runuser -u kyri-capability` with `HOME=/data/kyri/capability`.

## 6. Remote evidence

No releases. `actions/artifacts` total count `0`. No workflow builds, pushes or
pulls an image — every Podman mention in `ci.yml` is a comment asserting its
absence (*"no host state, no Podman, no network"*). Container package listing
needs a scope this token lacks, which is recorded as uninspected rather than
empty.

No public registry was searched by digest, and nothing was pulled.

## 7. `a3ef70ee` versus `5cee2b53`

They cannot be two views of one image. Both are recorded as image **IDs** — the
CIMP field is `oci_image_id`, the test constant is `IMAGE_ID`, and both are
produced by `podman image inspect --format '{{.Id}}'`. Two different values of
the *same* kind of identity are two different config blobs, so the
manifest-versus-config and index-versus-manifest explanations are excluded by
construction.

What remains: **two different builds.** Which §8 shows is what the procedure
produces every time it runs.

`a3ef70ee`'s provenance is a source comment saying *"the live facts this pass
was given"*, which the brief correctly rules insufficient. It is not authority,
and it is not a substitute.

**`A3EF_RELATION = DIFFERENT_IMAGE`** — different builds, on the evidence
available. The provisioning evidence would confirm it directly by naming the
`oci_image_id` and `source_commit` the admitted build actually had.

## 8. Build inputs, and why reproduction cannot work

The build context is deliberately **one file**: the Containerfile carries no
`COPY` and no `ADD`, asserted structurally by the ceremony.

| Input | Classification |
| --- | --- |
| Containerfile bytes | **KNOWN/GOVERNED** — `f543c458…`, and the working tree still matches |
| Base image reference + digest | **KNOWN/UNGOVERNED** — `cgr.dev/chainguard/python@sha256:84e1f28d…` survives only as a test constant; the governed copy is in the unread evidence |
| Build args | KNOWN — `BASE_IMAGE` only, no default by design |
| Architecture / os | KNOWN — linux/amd64 |
| Entrypoint, cmd, workdir, user | KNOWN/GOVERNED — in the Containerfile |
| Podman/Buildah version at build time | **MISSING** — not recorded in the evidence schema |
| Config `created` timestamp | **NONDETERMINISTIC** |

### The empirical proof

Run in isolated storage (`--root`/`--runroot` under a temporary directory);
production graphroot untouched:

```
build A id: 9222f71b2f7f8493253bbd5260b06e3c6a09dc7e176f78ce444899db8543b390
build B id: abd3973508b0d93c25d01ed3a2d3c027190642e36f172e5fa180a6ef55db9e9c
DIFFERENT — identical inputs, different image ID
created: 2026-08-30 17:21:11.615255916 +0000 UTC
```

Two builds of the same one-line Containerfile, seconds apart, byte-identical
inputs, different image IDs — because the image ID *is* the config digest and
the config carries `created`.

Neither `g5-ceremony.sh` nor either README passes `--timestamp`, sets
`SOURCE_DATE_EPOCH`, or uses `--omit-history`. Grepped: no determinism controls
exist anywhere in the build authority.

**`OCI_RECOVERY = EXACT_REPRODUCIBLE` is therefore unreachable**, and would be
even with the base digest in hand. It also explains `a3ef70ee ≠ 5cee2b53`
without needing anything to have gone wrong: a second build of the same
Containerfile that afternoon would necessarily differ.

No hash archaeology was attempted, per Part I.

## 9. Recovery decision

**`OCI_RECOVERY = UNRESOLVED`.**

- **Option B — reproduce: closed.** Proved impossible by construction (§8).
- **Option A — recover: open and unsearched.** The two places the artefact and
  its evidence are supposed to be have not been read, because both are
  deliberately outside the coordinator's reach. Reporting them as absent would
  repeat G11-AB's error with more confidence and no more evidence.
- **Option C — re-admit: premature.** The brief forbids it until A is
  investigated thoroughly, and A has not yet been investigated at all.

### The two commands that settle it

Read-only. Neither imports, builds, mutates, or executes anything.

```bash
# 1. The provisioning evidence: does it exist, and does it hash to 86762793...?
sudo sha256sum /root/kyri-g5-provisioning-evidence.json
sudo cat      /root/kyri-g5-provisioning-evidence.json

# 2. The store the image was actually loaded into.
sudo runuser -u kyri-capability -- env \
    HOME=/data/kyri/capability XDG_RUNTIME_DIR=/run/user/999 \
    podman images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Created}}'
```

If the evidence hashes to `86762793…`, it *is* the record CIMP-000001 cites, and
its `oci_image_id`, `base_image_reference`, `containerfile_sha256` and
`source_commit` fields settle §7 and §8 outright. If `5cee2b53…` appears in the
image list, the exact artefact is recovered.

## 10. If the artefact is recovered

Nothing is imported by this checkpoint. The ceremony would be:

1. freeze and review the artefact's authority — the evidence file, read and
   hashed, against the CIMP's `provisioning_evidence_digest`;
2. verify the local image ID is exactly `5cee2b53…` in the
   `kyri-capability` store, by the same `{{.Id}}` form the admission used;
3. confirm the image contract — architecture, interpreter path and digest,
   default user, absent shell and package manager — against the evidence fields;
4. no import is needed if it is already in that store; if it must be moved,
   import and then re-verify the ID after import;
5. record the linkage without touching CIMP-000001.

**CIMP-000001 could then legitimately remain the implementation authority**, and
should: it would be an accurate immutable record of an artefact that exists. The
only thing that was ever missing is the ability to *read* its evidence.

## 11. If it is not recovered

Then, and only then, option C. Sketched here so the decision is informed, not to
be acted on:

- a new Containerfile authority, or the surviving one re-used unchanged;
- the base pinned by digest, recorded in committed authority this time rather
  than only in a root-owned file and a test constant;
- one-file build context, unchanged;
- the resulting image ID taken from an actual build, never predicted;
- a fresh evidence record, and — the lesson of this checkpoint — **its digest and
  the image ID committed to the repository as well as to `/root`**, so a future
  audit can resolve them without privilege;
- the payload stays exactly CPKG-0001's governed entrypoint. No capability
  behaviour is expanded.

Given §8, whatever is built will have an ID nobody can predict or reproduce, so
the record must be written from the observed result.

## 12. New implementation identity

`CIMP` has **no supersedes field**. The lifecycle is admission plus an optional,
immutable, irreversible `retirement` — `PENDING_RETIREMENT` exists as a state and
*"an immutable retirement is not reversible by a later operator."* So a new
implementation is a **new root**, not a successor, and CIMP-000001 stays as
historical evidence whether or not it is retired.

The identity is allocated, not assumed: `allocate_cimp(control_fd)` advances a
counter under the implementation-lifecycle lock. `CIMP-000000` is reserved and
is never an implementation. The derived expectation is **CIMP-000002**, and it
would be produced by that allocator rather than chosen.

## 13. Re-admission dependency graph

Each edge derived from the records, not assumed. The decisive observation:

```
grep -rl "CIMP" /var/lib/kyri/fabric/   →  (no output)
```

**No Fabric record references an implementation at all.** CADV names host,
package and contract. CINST names capability, package and contract. Neither
names a CIMP. The implementation-authority plane and the Fabric chain are
orthogonal.

| Record | Required | Why |
| --- | --- | --- |
| New image | conditional | only if §9 finds nothing |
| New CIMP | conditional | follows the image; independent of the Fabric chain |
| **CPKG-0001** | **NO** | the package is the governed Python tree, not the image; no CPKG field references an implementation or an image |
| **Trust records** | **NO** | TREC-000001 and TREC-000002 are `state: trusted` with `expiration: null` and `expires_at: null` |
| **CADV-000004** | **YES** | CADV-000003 expires; ELIG-6 requires the named advertisement to be inside its window |
| **CINST-000003** | **YES** | CINST-000002's admission window ends at the same instant; ELIG-7 |
| **CROUTE-0003** | **YES** | G11-AC: selection iterates `candidate_instances`, and CROUTE-0002 names only CINST-000002 |
| **CSEL-000002** | **YES** | CSEL-000001 selects CINST-000002 |

So the renewal is required by expiry regardless of how the image question
resolves, and the image question does not add records to the Fabric chain.

## 14. Admission dependency bound

`admit_instance` checks the advertisement window, that admission did not begin
before the claim, and that `evaluated_at < admitted_until`. It does **not**
require `admitted_until <= advertisement.valid_until`. The current pair happens
to be exact — both `2026-08-30T16:19:19-05:00` — because an operator set it by
hand.

Structurally it is not a blocker: G11-Y already refuses the R17 tail at invoke
via ELIG-6, so an over-long admission fails closed rather than executing.

But the **next governed write is CINST-000003, which sets exactly this field**,
and getting it wrong produces a binding that looks admitted and refuses only at
invoke — after a renewal ceremony has been spent. The invariant guards precisely
the write that is next.

**`ADMISSION_BOUND_REQUIRED_BEFORE_NEW_CINST = YES`**, as defence in depth for
the imminent write rather than as a correctness gap. Not implemented here.

## 15. ELIG-6 head policy

`_advertised()` resolves the advertisement the *instance names* and checks only
`observed_at <= instant < valid_until`. Head-ness is not consulted, which is the
unresolved question: should a superseded-but-unexpired advertisement remain
eligible?

The renewal does not raise it. CINST-000003 will name CADV-000004, which will be
the head at admission. The question becomes live only if a further advertisement
supersedes CADV-000004 before it expires — not part of this renewal.

**`ELIG6_HEAD_POLICY_BLOCKS_RENEWAL = NO`.** Unchanged, and no policy invented.

## 16. Coordinator authority

Unchanged from G11-AB: `COORDINATOR_UID = 1000` is compiled into the privileged
transition helper and enforced twice on the launch record and profile; the
sudoers example names `cschott` literally; nothing derives or provisions either.

The helper is the component that carries a prepared invocation across the
privilege boundary. Deploying a working backend means running it, and running it
means relying on that identity check.

**`COORDINATOR_AUTHORITY_REQUIRED_BEFORE_BACKEND_DEPLOY = YES`.** No privileged
bytes were changed here.

## 17. Generation 13

Unchanged from G11-AB — G11-AC touched no installed object, and this checkpoint
changed no source at all. Pending contents:

| Object | Operation |
| --- | --- |
| `tools/capability/rehearsal.py` | CREATE |
| `tools/capability/store.py` | REPLACE |
| `tools/capability/evidence.py` | REPLACE |
| `tools/capability/package_resolution.py` | REPLACE |
| `tools/capability/coordinator.py` | REPLACE |
| `tools/capability/cli.py` | REPLACE |

70 → 71 objects. The G6 backend binding, when it exists, will add to the same
generation; the coordinator authority changes a *privileged helper*, which is
excluded from generations and installs in its own ceremony. **Smallest coherent
bundle: one Generation-13 package carrying the preflight and the backend, with
the helper ceremony run alongside it.** Not built or installed here.

## 18. Production non-mutation

| Surface | Value |
| --- | --- |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Fabric store | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Routes / sequence | CROUTE-0001, CROUTE-0002 / `2` |
| CIMP-000001 | unchanged, `ecb38d80…`, no retirement |
| Podman production graphroot | untouched; the reproduction test used `--root`/`--runroot` in a temporary directory |

No CIMP created or altered, no CADV/CINST renewal, no CROUTE-0003, no CSEL, no
CINV, no stage or invoke, no image imported or loaded, no runtime or sudoers
install, no Fabric, Trust or Evidence change. No source file modified.

## 19. Reviewer decisions required

1. **Run the two read-only commands in §9.** They are the whole of the remaining
   recovery question, and everything else waits on them.
2. **If the artefact is present:** confirm CIMP-000001 stands, and commit the
   image ID and evidence digest into repository authority so this audit is never
   needed again.
3. **If it is absent:** authorise option C under §11, accepting that the new
   image's ID cannot be predicted or reproduced and must be recorded from the
   build.
4. **Whether to record build determinism as a known property.** The procedure
   cannot produce a reproducible image ID. That is worth stating in the image
   README rather than leaving each future audit to rediscover it.
5. **The admission bound** (§14), before CINST-000003.

Carried forward unchanged: `WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`,
`ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`,
`SEMGREP_RULESET_POLICY=DYNAMIC`.
