# ENG-0005 G11-AE — OCI image authority resolution

**Date:** 2026-08-30
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `922e9e02d7483a71f26b83aee54420fb159cba0e`
**Implementation commit:** none — forensic resolution

**G11-AD was right to stop.** It ruled `OCI_RECOVERY=UNRESOLVED` rather than
`NOT_RECOVERABLE` on the grounds that the two decisive sources had never been
read, and that both sat behind privilege boundaries the coordinator cannot
cross by design. Operator inspection has now been performed, and G11-AD's
refusal to conclude was correct on both counts: **the evidence exists and hashes
exactly, and the exact governed image is present.** Had G11-AB's finding stood,
this checkpoint would have rebuilt an image and allocated a CIMP-000002 that
were never needed.

Three results, in order of consequence.

**The provisioning evidence is authentic, byte-exact.**
`/root/kyri-g5-provisioning-evidence.json` is 790 bytes hashing to
`86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac` — the
complete `provisioning_evidence_digest` CIMP-000001 committed to, compared in
full and not by prefix. It parses under the repository's own closed fifteen-field
validator, including the canonical-re-encoding check.

**The exact artefact survives.** Image ID
`5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` is present in
the `kyri-capability` rootless store, carrying the tag
`localhost/kyri-capability-execution:g5`.

**`a3ef70ee` is explained by committed authority, not by inference.** It was
built from the *3.14.7* base and was ruled **not admissible** on 2026-08-14. The
candidate was then replaced with the last 3.14.6 child and rebuilt. This is a
recorded governed supersession, and it supersedes G11-AD's §8 conjecture that
timestamp nondeterminism was the explanation.

`OCI_RECOVERY = EXACT_FOUND`. CIMP-000001 was not modified and remains the
legitimate implementation authority.

Two read-only privileged reads remain open; §12 states them exactly.

---

## 1. Starting authority

Reconstructed from the repository and the host, not from the continuation brief.

| Check | Observed |
| --- | --- |
| HEAD | `922e9e02d7483a71f26b83aee54420fb159cba0e` |
| origin/arch/eng-0005-execution-transition | identical; `rev-list --left-right --count` = `0 0` |
| Working tree | clean |
| G11-AD report commit `922e9e02` | HEAD |
| G11-AC report commit `2a4031ec` | ancestor |
| G11-AC implementation `bffb3c1e` | ancestor |
| Installed runtime | 70 objects, `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Fabric store | 21 files, `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Routes / sequence | CROUTE-0001, CROUTE-0002 / `2`, head CROUTE-0002 |

No pull was required; the branch was already synchronized. Nothing was reset,
rebased or rewritten.

## 2. CIMP-000001, read from live authority

Read from `/var/lib/kyri/implementation-authority/implementations/CIMP-000001/admission`,
verbatim:

```json
{"adapter_identity":"python-podman-v1","argv_contract_identity":"fixed-python-entrypoint-v1",
 "cimp":"CIMP-000001","execution_profile_schema_version":2,
 "oci_image_id":"5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190",
 "payload_schema_version":1,
 "provisioning_evidence_digest":"86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac"}
```

| Field | Value |
| --- | --- |
| `cimp` | `CIMP-000001` |
| `adapter_identity` | `python-podman-v1` |
| `argv_contract_identity` | `fixed-python-entrypoint-v1` |
| `execution_profile_schema_version` | `2` |
| `payload_schema_version` | `1` |
| `oci_image_id` | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` |
| `provisioning_evidence_digest` | `86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac` |

The record's own SHA-256 is `ecb38d80dd0e9ee444b182811fd556184b085e5e0cec236bf012228f0dc9991b`,
which is exactly the `admission` digest carried by the CGEN-000000000001
authority set:

```json
{"entries":[{"admission":"ecb38d80dd0e9ee444b182811fd556184b085e5e0cec236bf012228f0dc9991b",
             "cimp":"CIMP-000001","retirement":null}]}
```

The implementation directory holds one file, `admission`. **No retirement is
published**, confirmed by directory contents rather than by a null field alone.

**Full expected provisioning-evidence digest:**
`86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac`. Every
comparison below uses this complete value.

## 3. The evidence file

`sudo sha256sum /root/kyri-g5-provisioning-evidence.json` returned:

```
86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac  /root/kyri-g5-provisioning-evidence.json
```

**Exact match to CIMP-000001, over the complete 64-hex value.**

The comparison is sound without qualification. `evidence_digest()` is
`hashlib.sha256` over the entire body, and `verify_production_evidence` feeds it
`open(path, "rb").read()` — the whole file. So `sha256sum` of the file is
literally the quantity the admission committed to. There is no canonicalisation
step between the two that could hide a difference.

### Structural validation

The body was reconstructed byte-exactly (790 bytes, no trailing newline;
independently confirmed by its digest reproducing `86762793…b2ac`) and put
through the repository's actual validator, `tools/provisioning/provisioning_evidence.parse_evidence`:

```
bytes: 790
evidence_digest(): 86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac
PARSE: OK — canonical, closed 15-field schema satisfied
field count: 15 expected: 15
```

That is not a shallow parse. `parse_evidence` refuses unknown fields, refuses
missing fields, enforces `evidence_schema_version == 1`, requires
`oci_image_id` to be bare 64-hex (a `sha256:` prefix is structurally
unrepresentable), requires `containerfile_sha256`/`interpreter_sha256`/`sbom_sha256`
to be SHA-256, requires `source_commit` to be 40-hex, requires
`base_image_reference` to be a digest-pinned `cgr.dev/chainguard/python`
reference, requires `python_version` and `sbom_python_version` to equal the
governed `3.14.6` exactly, requires `sbom_python_package == "python-3.14"`,
requires `interpreter_path == CONTAINER_INTERPRETER`, and finally **re-serialises
and refuses bytes that are not their own canonical encoding**. All of it passed.

### Contents

| Field | Value |
| --- | --- |
| `architecture` | `amd64` |
| `base_image_reference` | `cgr.dev/chainguard/python@sha256:4b14dc70f04229cafd97b34ef34b16e1e09bdcac6362097cd5c582dca3eff686` |
| `containerfile_sha256` | `f543c458fcb1793570010b58417c175e6510fe0d90d2a295ef9d38b0cfdedcbb` |
| `evidence_schema_version` | `1` |
| `interpreter_link` | `python3` |
| `interpreter_path` | `/usr/bin/python` |
| `interpreter_sha256` | `041b9331ce282a8ffeb8e36c662a3a2991f692c8d90633e921e37a1bdafb0de0` |
| `interpreter_target` | `/usr/bin/python3.14` |
| `oci_image_id` | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` |
| `os` | `linux` |
| `python_version` | `3.14.6` |
| `sbom_python_package` | `python-3.14` |
| `sbom_python_version` | `3.14.6` |
| `sbom_sha256` | `eb9acc161dd5eb7622f3f8ca09b8f9a8f679ea7ac0f6ba7d10f48ec0cca228e3` |
| `source_commit` | `5fca69d126e2d52c637574ddcb39b571f0e882e2` |

`PROVISIONING_EVIDENCE = VALID`.

## 4. The `kyri-capability` image inventory

Run as uid 999 with `HOME=/data/kyri/capability`, `XDG_RUNTIME_DIR=/run/user/999`.
Both values were confirmed against the host before the command was issued:
`kyri-capability` is `uid=999 gid=987`, and `/run/user/999` exists owned by it.

```
sha256:5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190 localhost/kyri-capability-execution:g5 2 weeks ago
sha256:a3ef70eee8c906c4604f53bb1874ab5bf4922bab9c5f0ba6b6d9ce126f589b69 <none>:<none>                            2 weeks ago
sha256:a33976e6c3275bab76c89686561e5b8cacf6c6f40b70ec67a3d01c8cf8c2bdd6 cgr.dev/chainguard/python:<none>        2 weeks ago
sha256:4090f44b5b3c75835c4f41cb5b3c6efa0cc3abbe66a055a1fd017d60eb6803ff cgr.dev/chainguard/python:<none>        3 weeks ago
sha256:bf8527eb54c3680e728d5b4b383a8ba730d72dae7236fbc8dff97ed6b224a731 docker.io/library/alpine:<none>         4 months ago
```

The first attempt failed before Podman executed, because `kyri-capability`
cannot `chdir` into the coordinator-owned repository. Rerunning from `/tmp`
succeeded. **No permission was changed to obtain this output** — the correct
response to a directory the execution identity cannot enter was to run from one
it can.

### The store is exactly what the design predicts

Five images, and every one is accounted for by committed authority:

| Image ID | Identity |
| --- | --- |
| `5cee2b53…` | **the admitted implementation**, tagged `kyri-capability-execution:g5` |
| `a3ef70ee…` | the non-admissible 3.14.7 build, untagged, inert |
| `a33976e6…` | config digest of the **superseded** 3.14.7 base `84e1f28d…` (`g5-supply-chain.sh:151`) |
| `4090f44b…` | config digest of the **governed** 3.14.6 base `4b14dc70…` (`README:1084`) |
| `bf8527eb…` | `docker.io/library/alpine`, Track-B residue, deferred to G7 |

Two independent corroborations fall out of this. The base image the evidence
names is **physically present in the same store**: `README:1084` records
`sha256:4090f44b…` as the config digest of the 3.14.6 child `4b14dc70…`, and a
pulled image's containers/storage local ID *is* its config digest — so
`4090f44b…` in the listing is that base. And the superseded 3.14.7 base is
present too, as `a33976e6…`, matching `g5-supply-chain.sh:151` exactly.

## 5. `5cee2b53…` presence

**Present. Exact, full 64-hex match**, compared over the complete value:

```
CIMP-000001 oci_image_id : 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
evidence    oci_image_id : 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
kyri-capability store    : 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

The `sha256:` prefix in the Podman listing is a rendering artefact of
`{{.ID}}` under `--no-trunc`, not part of the identity.
`RootlessImageStore._identities()` reads the bare `id` field of
`overlay-images/images.json` and ignores names, tags, digests and history
entirely, so resolution depends on this hex string and on nothing else in the
listing. The tag `kyri-capability-execution:g5` is corroboration for a human
reader, not an input to resolution.

`EXACT_ARTIFACT_AVAILABLE = YES`.

## 6. Image metadata

**Not obtained.** `podman image inspect` against the `kyri-capability` store
requires the same privilege boundary as §4, and this session has no TTY — the
authorised command was executed and returned `sudo: a terminal is required to
read the password`. This was established by running the real command, not by
inferring from `sudo -n`.

So the following remain uncollected: created timestamp, architecture and OS as
the image reports them, entrypoint, command, working directory, configured user,
environment, labels, config identity and layer identities.

`IMAGE_METADATA_MATCH = NOT_RUN`. The exact command is in §12.

This does **not** hold up the recovery ruling. The Case-A test is evidence
digest ∧ structural validity ∧ exact image ID present, and all three are
satisfied. Metadata inspection deepens the evidence↔image correspondence; it is
not a precondition for it.

What the metadata *would* be checked against, when collected, is already fixed
by `g5-ceremony.sh:154-157` and was not invented here:

| Property | Governed expectation | Source |
| --- | --- | --- |
| `os` | `linux` | `IMAGE_EXPECT_OS` |
| `architecture` | `amd64` | `IMAGE_EXPECT_ARCHITECTURE` |
| default user | `65532:65532` | `IMAGE_EXPECT_USER` |
| working directory | `/` | `IMAGE_EXPECT_WORKINGDIR` |
| entrypoint | empty | Containerfile `ENTRYPOINT []` |
| command | empty | Containerfile `CMD []` |

## 7. Evidence ↔ image correspondence

| Relation | Status |
| --- | --- |
| evidence `oci_image_id` = CIMP `oci_image_id` | **MATCH**, full 64-hex |
| evidence file SHA-256 = CIMP `provisioning_evidence_digest` | **MATCH**, full 64-hex |
| named image present in the governed store | **YES** |
| evidence `base_image_reference` present in store as its config digest | **YES** (`4090f44b…`) |
| evidence `containerfile_sha256` = tree Containerfile | **MATCH** |
| evidence `source_commit` is a real ancestor of HEAD | **YES** |
| image runtime metadata ↔ evidence `os`/`architecture` | **NOT_RUN** (§6) |

The chain closes at three points independently: the admission commits to the
evidence by digest, the evidence names the image, and the image is in the store
under that name. Each link was verified over complete values.

## 8. `main.py` — mounted, not embedded

Definitive, and it matters for the G6 backend work that follows.

`provisioning/image/Containerfile` carries **no `COPY` and no `ADD`** — verified
directly, and structurally asserted by the ceremony, whose build context is one
file deliberately (`g5-ceremony.sh:161`, *"the Containerfile carries no COPY and
no ADD"*, with `--verify-build-context` refusing a context that grows one).

The image therefore contains no governed payload at all. It contains four
`WORKDIR` declarations that exist solely as bind-mount destinations, and they
correspond exactly to the worker's constants:

| Containerfile `WORKDIR` | `worker.py` constant | Mount |
| --- | --- | --- |
| `/kyri/package` | `PACKAGE_DESTINATION` | `ro=true` |
| `/run/kyri/input` | `PAYLOAD_DESTINATION` = `/run/kyri/input/payload` | `ro=true` |
| `/kyri/output` | `OUTPUT_DESTINATION` | `ro=false` |
| `/` | — | final working directory |

The governed package tree is exactly one file, and it is in the artifact
authority, not the image:

```
/var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0/main.py
/var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0.manifest.json
```

with `package_tree_sha256 = sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e`,
bound to CPKG-0001 / CCON-0001 / CAPDEF-0001.

The container command is assembled as `profile.oci_image_id`, then
`CONTAINER_INTERPRETER`, then `_container_entrypoint(...)` — that is,
`/usr/bin/python /kyri/package/main.py`, with the entrypoint required to be a
relative, traversal-free `.py` path resolved under the read-only mount. The
image's own `ENTRYPOINT` is cleared precisely so this command is not prefixed by
a second interpreter.

Two further consequences worth stating, because both bear on the backend:

- **The image's `USER 65532:65532` is metadata only.** Every container is
  launched with an explicit `--user 1000:1000` (`CONTAINER_UID`/`CONTAINER_GID`),
  and profile verification compares what Podman reported against that. The
  Containerfile says so in terms.
- **The image is immutable at runtime**: `--read-only`, `--read-only-tmpfs=false`,
  a 16 MiB `/tmp` tmpfs, `--memory 256m`, `--memory-swap 256m`, and a governed
  `--network`.

**`MAIN_PY_EMBEDDED = NO`. It is supplied from governed CPKG-0001 staging by
read-only bind mount.** No image change is implied by any future package change,
which is the property the separation was built for.

## 9. The fifteen build inputs

Compared against committed repository authority and live production authority.
`MATCH` means an independent recorded value agrees; `UNVERIFIABLE` means no
authority outside the evidence itself records it *and* the only way to observe it
is forbidden here.

| # | Field | Value | Class | Independent authority |
| --- | --- | --- | --- | --- |
| 1 | `architecture` | `amd64` | **MATCH** | `IMAGE_EXPECT_ARCHITECTURE`, `g5-ceremony.sh:155` |
| 2 | `base_image_reference` | `…@sha256:4b14dc70…` | **MATCH** | `provisioning/execution/README.md:1083` — the linux/amd64 child of the governed 3.14.6 base; its config digest `4090f44b…` is present in the store |
| 3 | `containerfile_sha256` | `f543c458…` | **MATCH** | working tree **and** the tree at `5fca69d1` both hash to `f543c458…` |
| 4 | `evidence_schema_version` | `1` | **MATCH** | `EVIDENCE_SCHEMA_VERSION = 1` |
| 5 | `interpreter_link` | `python3` | UNVERIFIABLE | an image-filesystem fact; reading it requires running or mounting the image |
| 6 | `interpreter_path` | `/usr/bin/python` | **MATCH** | `CONTAINER_INTERPRETER`, `worker.py:123`; validator enforces equality |
| 7 | `interpreter_sha256` | `041b9331…` | UNVERIFIABLE | image-filesystem fact; recorded nowhere in the repository |
| 8 | `interpreter_target` | `/usr/bin/python3.14` | UNVERIFIABLE | image-filesystem fact; consistent with the 3.14 series but not independently recorded |
| 9 | `oci_image_id` | `5cee2b53…` | **MATCH** | CIMP-000001 **and** the `kyri-capability` store |
| 10 | `os` | `linux` | **MATCH** | `IMAGE_EXPECT_OS`, `g5-ceremony.sh:154` |
| 11 | `python_version` | `3.14.6` | **MATCH** | `GOVERNED_PYTHON_VERSION`; `g5-supply-chain.sh:141`; README records `cpython v3.14.6` for `4b14dc70…` |
| 12 | `sbom_python_package` | `python-3.14` | **MATCH** | `GOVERNED_SBOM_PACKAGE`; `g5-supply-chain.sh:142` |
| 13 | `sbom_python_version` | `3.14.6` | **MATCH** | validator enforces equality with the governed version; README records `python-3.14 3.14.6-r4` |
| 14 | `sbom_sha256` | `eb9acc16…` | UNVERIFIABLE | **closable** — recorded only in `/root/kyri-g5-approved-base.txt` (§12) |
| 15 | `source_commit` | `5fca69d1…` | **MATCH** | real commit, ancestor of HEAD, *"feat(provisioning): rule the signed Chainguard SBOM package, and discover by version"*, 2026-08-14 |

**11 MATCH, 4 UNVERIFIABLE, 0 MISMATCH.** `BUILD_INPUTS = PARTIAL`.

Nothing contradicts anything. Of the four open fields, exactly one —
`sbom_sha256` — is closable within this checkpoint's authority. The three
`interpreter_*` fields are observations of the image's filesystem, and the only
ways to read them are running the image or mounting its layers, both forbidden
here. They should be recorded as structurally unverifiable at this privilege
rather than left to be rediscovered.

### A correction to G11-AD §8

G11-AD classified the base reference **KNOWN/UNGOVERNED**, *"survives only as a
test constant"*, citing `84e1f28d…`. That is wrong in both parts, and the error
propagated from G11-AB.

`84e1f28d…` is the **superseded 3.14.7 candidate**, and its appearance in
`tests/test-capability-execution-g5-authority.sh:86` is a synthetic fixture — the
file labels those constants *"the live facts this pass was given"* and uses them
to drive the ceremony harness, alongside the equally synthetic
`IMAGE_ID="a3ef70ee…"` and `SBOM="18843222…"`. None of the three is authority.

The governed base **is** committed, at `provisioning/execution/README.md:1083`,
and it matches the evidence exactly. So field 2 is `MATCH` against committed
repository authority, and the approval file is *not* required to close the
base-image question — only the SBOM one.

## 10. `a3ef70ee` versus `5cee2b53` — settled by record

G11-AD reached `DIFFERENT_IMAGE` and was right. But its §8 mechanism — that a
second build minutes later would differ because the config embeds `created` — is
not what happened, and the actual reason is recorded in committed authority that
earlier passes did not reach.

`provisioning/execution/README.md` §"Disposition of the built image `a3ef70ee…`"
rules, on 2026-08-14:

> It was built from the 3.14.7 base and is **not admissible**. It is admitted by
> nothing, so it grants nothing — an image in the store with no `CIMP` is inert,
> exactly as Track-B residue is. Leave it. Removing it is not required for G5
> and […] is deferred to **G7**. Do not reuse its tag: the replacement build
> must produce a new `.Id`, and `kyri-capability-execution:g5` must be
> re-pointed by the build.

The sequence was: discover `84e1f28d…`; build `a3ef70ee…` from it; read the
signed SBOM and find it reports **3.14.7**, against a governed **3.14.6**; rule
*replace the candidate, do not migrate the governed version*; retire the
approval rather than edit it; walk Chainguard's tag history back to the last
`:latest` carrying 3.14.6 (index `1bd5d5a1…`, child `4b14dc70…`, config
`4090f44b…`); rebuild; admit the result as CIMP-000001.

The live store is exactly consistent with that ruling, in a way that would be
difficult to fake: `a3ef70ee…` is `<none>:<none>` — untagged, because the tag was
re-pointed as instructed — and `5cee2b53…` carries
`localhost/kyri-capability-execution:g5`. Both bases are still present, the
superseded one and the governed one.

So the two images differ because they were **built from different base images
under a recorded supersession**, not because of build nondeterminism.
G11-AD's determinism finding remains independently true and still closes
Option B; it simply was never needed to explain this pair.

**`A3EF_RELATION = DIFFERENT_IMAGE`.** It must not be substituted for
`5cee2b53…`, and it is explicitly not admissible. Its removal stays deferred to
G7; this checkpoint removed nothing.

## 11. Rulings

| Field | Value | Derivation |
| --- | --- | --- |
| `OCI_RECOVERY` | **EXACT_FOUND** | evidence digest exact ∧ evidence validates ∧ exact image ID present |
| `EXACT_ARTIFACT_AVAILABLE` | **YES** | §5 |
| `PROVISIONING_EVIDENCE` | **VALID** | §3 |
| `NEW_IMAGE_REQUIRED` | **NO** | the governed artefact exists; §11 of G11-AD's option C is not reached |
| `NEW_CIMP_REQUIRED` | **NO** | CIMP-000001 accurately describes an artefact that exists |
| `CIMP_000001_PRESERVED` | **YES** | unmodified; `ecb38d80…` before and after |

These were derived, not accepted. Case A's three conditions were each tested
over complete values, and Case C — image present but evidence mismatched — was
specifically excluded by the exact digest match in §3.

**CIMP-000001 remains the legitimate immutable implementation authority and
remains usable.** It is an accurate record of an artefact that is present in the
store it was loaded into. The only thing ever missing was the privilege to read
its evidence. No re-admission, no retirement, no CIMP-000002.

Option B stays closed on G11-AD's proof, and is now moot.

## 12. The remaining privileged reads

Two, both read-only, both narrowly scoped. Neither imports, builds, tags,
removes, mutates or executes anything.

**A — image metadata (§6).** Completes the evidence↔image correspondence:

```bash
cd /tmp && sudo runuser -u kyri-capability -- env \
    HOME=/data/kyri/capability XDG_RUNTIME_DIR=/run/user/999 \
    podman image inspect --format '{{json .}}' \
    5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

Optionally, to bind the built image to the governed base by manifest digest:

```bash
cd /tmp && sudo runuser -u kyri-capability -- env \
    HOME=/data/kyri/capability XDG_RUNTIME_DIR=/run/user/999 \
    podman image inspect --format '{{.Id}} {{json .RepoDigests}}' \
    4090f44b5b3c75835c4f41cb5b3c6efa0cc3abbe66a055a1fd017d60eb6803ff
```

`cd /tmp` matters: `kyri-capability` cannot enter the coordinator-owned
repository, and the fix is to run from a directory it can, never to widen a
permission.

**B — the SBOM approval, and only that file (§9 field 14).** Required, and
required for one field:

```bash
sudo cat /root/kyri-g5-approved-base.txt
```

It holds `base_image_reference=` and `sbom_sha256=`, and it is the record
`verify_production_evidence` cross-checks the evidence against
(`g5-ceremony.sh:998-1016`). Reading it turns field 14 from UNVERIFIABLE to a
decided comparison against `eb9acc161dd5eb7622f3f8ca09b8f9a8f679ea7ac0f6ba7d10f48ec0cca228e3`,
and independently re-confirms field 2. No other root-owned file is needed, and
none was read: `/root/kyri-g5-candidate-evidence.txt` and the retired
`…-retired-84e1f28d.txt` are not requested.

Privilege is not broadened beyond these. Neither read blocks the §11 rulings.

## 13. Current chain expiry

Observed, not assumed:

| Record | Field | Value |
| --- | --- | --- |
| CADV-000003 | `valid_until` | `2026-08-30T16:19:19-05:00` |
| CINST-000002 | `admitted_until` | `2026-08-30T16:19:19-05:00` |

Observed at `2026-08-30T18:29:13-05:00`, **2h 09m past the endpoint**.

**`CURRENT_PRODUCTION_CHAIN_EXPIRED = YES`.** Expected and safe: production
invoke remains unauthorised, ELIG-6 and ELIG-7 fail closed on an expired
advertisement and admission, and nothing was renewed. The window was allowed to
lapse deliberately, as G11-AD recorded.

Renewal remains required by expiry and is independent of the image question,
which §13 of G11-AD established and this checkpoint does not disturb:
CADV-000004, CINST-000003, CROUTE-0003, CSEL-000002. **None was created here.**
`NEW_CPKG_REQUIRED = NO` and `NEW_TRUST_REQUIRED = NO` stand — no Fabric record
references a CIMP, so resolving the implementation plane added no Fabric work.

## 14. Carried dependencies

| Dependency | State | Why |
| --- | --- | --- |
| `ADMISSION_BOUND_REQUIRED_BEFORE_NEW_CINST` | **YES** | `admit_instance` does not require `admitted_until <= advertisement.valid_until`; the next governed write is CINST-000003, which sets exactly that field. Not implemented here. |
| `COORDINATOR_AUTHORITY_REQUIRED_BEFORE_BACKEND_DEPLOY` | **YES** | `COORDINATOR_UID = 1000` is compiled into the privileged transition helper; uid 1000 is not a universal Kyri invariant, it is what `schai` happens to use for `cschott`. No privileged bytes changed. |
| `GEN13_REQUIRED` | **YES** | six objects pending, 70 → 71. G11-AC's route-head change is not installed in Generation 12 and needs no repackaging on its own. Not built, not installed. |

§8's finding sharpens the Generation-13 picture usefully: because `main.py` is
mounted rather than embedded, the G6 backend binding is a runtime-package
concern only. It implies no image work, and CIMP-000001 needs no reissue to
support it.

## 15. Production non-mutation

Before and after all work, by identical measurement:

| Surface | Value |
| --- | --- |
| CIMP-000001 admission | `ecb38d80dd0e9ee444b182811fd556184b085e5e0cec236bf012228f0dc9991b`, one file, no retirement |
| Fabric store | 21 files, `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Installed runtime | 70 objects, `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Routes / sequence / head | CROUTE-0001, CROUTE-0002 / `2` / CROUTE-0002 |
| `kyri-capability` Podman store | read-only listing only; five images before, five after |
| Filesystem permissions | unchanged; the `chdir` failure was resolved by changing directory, not mode |

No CIMP created, altered or retired. No image loaded, pulled, built, tagged or
removed. No container run. No CADV, CINST, CROUTE, CSEL, CINV or CRES written.
No stage, no invoke. No runtime or sudoers install. No privileged helper change.
No Fabric, Trust or Evidence mutation. Root Authority not mounted. No tracked
source file modified — `IMPLEMENTATION_COMMIT = NONE`.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 16. Findings for later checkpoints

Recorded, not acted on.

1. **`5cee2b53…` and `86762793…` are still absent from repository authority.**
   This audit existed only because they were unreadable without privilege. Both
   should be committed — the image ID and the evidence digest — so no future
   pass needs `sudo` to answer this question. This is the lesson G11-AD drew in
   its §11 and it applies to the *surviving* record, not only to a replacement.
2. **`g5-supply-chain.sh:149-151` still hardcodes the superseded candidate**
   (`fe9ad068…` / `84e1f28d…` / `a33976e6…`) as `CANDIDATE_*`, while the governed
   base is `4b14dc70…` with config `4090f44b…`. `README:1118` directs that
   discovery and approval be rerun for `4b14dc70…`. The constants were not
   updated. Not corrected here — it is a tracked-source change, and this
   checkpoint is forensic.
3. **The G5 test fixtures describe the non-admissible image.**
   `tests/test-capability-execution-g5-authority.sh:85-88` carries `a3ef70ee…`,
   `84e1f28d…` and `18843222…`. They are legitimate synthetic harness inputs,
   but they read as live facts and misled two consecutive passes. A comment
   distinguishing fixture from authority would have prevented this audit.
4. **Build determinism should be documented as a known property.** G11-AD's
   §8 proof stands: the procedure cannot produce a reproducible image ID, since
   the ID is the config digest and the config embeds `created`. Worth stating in
   the image README rather than leaving each audit to rediscover it.
5. **Three `interpreter_*` evidence fields are unverifiable at any privilege
   short of reading the image filesystem.** If that matters, the ceremony would
   need to bind them to something observable from outside.

## 17. Next checkpoint

**G11-AF.** Obtain the two §12 reads; complete the image-metadata comparison
against `IMAGE_EXPECT_*` and the evidence; close `sbom_sha256`; then rule
`IMAGE_METADATA_MATCH` and re-rule `BUILD_INPUTS`. The §11 rulings are not
contingent on it.

After that, the renewal sequence — with the §14 admission bound implemented
**before** CINST-000003 is written, since that write sets the field the
invariant guards.

Carried forward unchanged: `WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`,
`ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`, `SEMGREP_RULESET_POLICY=DYNAMIC`.
`ELIG6_HEAD_POLICY_BLOCKS_RENEWAL=NO`.
