# ENG-0005 G11-AF — OCI metadata and base-approval closure

**Date:** 2026-08-30
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `ae49a57b363f4ee3af85346e0d8b33edcfae51d6`
**Implementation commit:** none — forensic closure

Both G11-AE gaps are closed, and nothing mismatched.

**The image is exactly what the evidence says it is.** `podman image inspect`
resolves `5cee2b53…` with `Architecture=amd64`, `Os=linux`,
`Config.User=65532:65532`, `Config.WorkingDir=/`, and **no `Entrypoint` and no
`Cmd` keys at all**. Every property the G5 ceremony governs passes.

**The image names its own base, and it is the governed one.** The annotation
`org.opencontainers.image.base.name` is
`cgr.dev/chainguard/python@sha256:4b14dc70…`, byte-identical to the evidence's
`base_image_reference`. The build history's first instruction records the same
`FROM`. That is the base question answered by the artefact itself, not by
inference.

**The approval file passes the repository's own verifier.** `--verify-approval`
returns *"the production approval is complete, digest-pinned, and
signer-bound"*, and its `sbom_sha256` equals the evidence's exactly.

Final matrix: **12 MATCH, 3 UNVERIFIABLE, 0 MISMATCH.** The three remaining are
interpreter filesystem facts, and they stay `UNVERIFIABLE` — inspect cannot
reach inside a filesystem, and the rule was not weakened to close them.

`CIMP_000001_BACKEND_USABLE = YES`.

One structural finding beyond the brief: **the built image adds zero filesystem
layers over its base.** All seven Containerfile instructions are
`empty_layer: true`. The image is filesystem-identical to Chainguard's, which
proves from the artefact — not merely from the absence of `COPY` — that no
payload was ever embedded.

---

## 1. Starting authority

| Check | Observed |
| --- | --- |
| HEAD | `ae49a57b363f4ee3af85346e0d8b33edcfae51d6` |
| origin | identical; `rev-list --left-right --count` = `0 0` |
| Working tree | clean |
| G11-AE report commit | HEAD |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Fabric store | 21 files, `bcb2559b…f15e` |
| Routes / sequence / head | CROUTE-0001, CROUTE-0002 / `2` / CROUTE-0002 |
| CIMP-000001 | `ecb38d80…9991b`, one file, no retirement |

The continuation brief was not treated as superseding committed source; every
value below was re-read from the repository, the host, or the operator's
verbatim output.

## 2. The G11-AE ruling this builds on

`OCI_RECOVERY = EXACT_FOUND`. The provisioning evidence is authentic — 790 bytes
hashing to `86762793aeac87694c69c88812436d64efaf1e762633ec8f929c1ba298cdb2ac`,
the complete CIMP-000001 `provisioning_evidence_digest` — and it passes
`parse_evidence` including the canonical re-encoding check. The exact image is
present in the governed `kyri-capability` store. CIMP-000001 is immutable and
unmodified.

Left open: image metadata (`IMAGE_METADATA_MATCH = NOT_RUN`) and `sbom_sha256`
(`BUILD_INPUTS = PARTIAL`, 11/4/0). Both are closed here.

## 3. Operator evidence

Two read-only sources, exactly the two G11-AE §12 requested and no more.

`podman image inspect 5cee2b53…` run as `kyri-capability` (uid 999) with
`HOME=/data/kyri/capability`, `XDG_RUNTIME_DIR=/run/user/999`, from `/tmp`.

`sudo cat /root/kyri-g5-approved-base.txt`.

No container was created or started, no image mounted, no tag altered, nothing
built, pulled, loaded or removed. `/root/kyri-g5-candidate-evidence.txt` and the
retired `…-retired-84e1f28d.txt` were not requested and not read.

## 4. Exact image identity

The image was selected by **ID**, not by tag, and the returned `Id` is:

```
5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

Compared over the complete 64-hex value against CIMP-000001's `oci_image_id` and
the evidence's `oci_image_id`. **Three-way exact match.**

The tag is corroboration only. `RootlessImageStore._identities()` reads the bare
`id` field of `overlay-images/images.json` and ignores names, tags, digests and
history, so nothing about `localhost/kyri-capability-execution:g5` participates
in resolution.

### The manifest digest is a different object, and that is the point

```
Id     : 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
Digest : sha256:8a168ccdad2a2d4eb6cb22c1cb87ad5b2f53b975dcc9bc1037d2f5c4e022bf5e
```

`Digest` and the sole `RepoDigests` entry are the **manifest** digest, and it is
nothing like the image ID. This is direct empirical confirmation of the semantic
ruling G11-AD derived from source: `oci_image_id` is the containers/storage
local image ID — the config blob digest — and a manifest digest is a different
kind of object that must never be substituted. The ceremony says so in terms
(*"the local RepoDigest is not the implementation identity and is recorded as
none"*), and the artefact now demonstrates it.

## 5. Image metadata

Captured mechanically from the operator's JSON.

| Property | Observed | Governed expectation | Source of expectation | Result |
| --- | --- | --- | --- | --- |
| `Id` | `5cee2b53…f5190` | CIMP `oci_image_id` | CIMP-000001 | **PASS** |
| `Architecture` | `amd64` | `amd64` | `IMAGE_EXPECT_ARCHITECTURE` | **PASS** |
| `Os` | `linux` | `linux` | `IMAGE_EXPECT_OS` | **PASS** |
| `Config.User` | `65532:65532` | `65532:65532` | `IMAGE_EXPECT_USER` | **PASS** |
| `Config.WorkingDir` | `/` | `/` | `IMAGE_EXPECT_WORKINGDIR` | **PASS** |
| `Config.Entrypoint` | **key absent** | empty | Containerfile `ENTRYPOINT []` | **PASS** |
| `Config.Cmd` | **key absent** | empty | Containerfile `CMD []` | **PASS** |

`verify_production_image` checks exactly these seven and nothing else. Its
`empty_config_list` helper accepts `""`, `"[]"`, `"<nil>"` and `"null"` —
Podman omits both keys entirely here, which is the same condition.

**`IMAGE_METADATA_MATCH = PASS`**, with all seven governed properties satisfied
and none merely assumed.

Other captured facts:

| Field | Value |
| --- | --- |
| `Created` | `2026-08-14T20:29:22.623744987Z` = `2026-08-14T15:29:22-05:00` |
| `Parent` | `a9c6a2355d1a06c732ffc1131564ab8cd122d992cad4f97a3b552b009834fc19` |
| `ManifestType` | `application/vnd.oci.image.manifest.v1+json` |
| `Size` / `VirtualSize` | `67563412` |
| `RootFS.Type` / layers | `layers` / **11** |
| `Config.Env` | `PATH=…`, `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` |
| Labels | nine, all Chainguard/apko, plus `io.buildah.version: 1.33.7` |

### The build adds no filesystem

History carries 18 entries: 11 apko entries dated `2026-08-05T03:14:25Z`, then
the seven Containerfile instructions dated `2026-08-14T20:29:22.x`. **All seven
are `empty_layer: true`**, and `RootFS.Layers` has 11 members — the 11 the base
contributed.

So the built image's filesystem is identical to Chainguard's `4b14dc70…`. Only
config metadata differs, which is also why the image ID changed while no layer
did. G11-AE inferred "`main.py` is not embedded" from the absence of `COPY`/`ADD`
in the Containerfile; the artefact now proves it independently, and proves it for
*anything* that might have been added, not just for the payload.

The seven instructions also appear in history in exactly the Containerfile's
order — `WORKDIR /kyri/package`, `WORKDIR /kyri/output`,
`WORKDIR /run/kyri/input`, `WORKDIR /`, `ENTRYPOINT []`, `CMD []`,
`USER 65532:65532` — through six intermediate images ending at `Parent`
`a9c6a2355d1a…`. That is instruction-for-instruction correspondence with the
file whose SHA-256 is `f543c458…`. It is descriptive metadata rather than a
cryptographic binding, and is recorded as corroboration, not as proof of the
Containerfile digest.

### A recovered build fact, and a corrected timeline

`io.buildah.version: 1.33.7` supplies the build-tool version G11-AD listed as
**MISSING — not recorded in the evidence schema**. It is still absent from the
closed fifteen fields, but it is recoverable from the artefact.

The real ceremony window is now visible, and it is not the one G11-AD inferred:

| Time (America/Chicago) | Event | Source |
| --- | --- | --- |
| 2026-08-04 22:14:25 | base image built by Chainguard | `org.opencontainers.image.created` |
| 2026-08-14 **15:26:40** | base approved | approval `approved_at` |
| 2026-08-14 **15:29:22** | production image built | image `Created` |
| 2026-08-14 **15:37:28** | CIMP-000001 admitted | admission record mtime |

An eleven-minute approve → build → admit sequence, internally consistent across
three independent artefacts. G11-AD's timeline gave the build window as
2026-08-14 13:25, taken from the mtime of `/data/kyri/capability`; that is a
top-level directory mtime and reflects something else. **The correct window is
15:26–15:37.**

## 6. The approved-base record

### Schema

The executable authority is `APPROVAL_FIELDS` in `g5-supply-chain.sh:584`, and
it names **fourteen** mandatory fields. The supplied file carries exactly those
fourteen, no more and no fewer.

Worth recording: `provisioning/execution/README.md:1381-1386` documents the
approval as **twelve** fields, omitting `sbom_python_package` and
`sbom_python_version`. The script is right and the prose is stale. Not corrected
here — this is a forensic checkpoint.

### Verified by the repository's own verifier

Run against a scratchpad fixture, so no production path was touched and the
`root:root 0400` ownership assertion was relaxed as fixture mode intends:

```
$ bash provisioning/execution/g5-supply-chain.sh --verify-approval --fixture <scratch>
note     FIXTURE MODE: operating under <scratch>; ownership checks relaxed
ok       the production approval is complete, digest-pinned, and signer-bound

G5 supply chain verify-approval: all checks passed.
Nothing was downloaded, installed, pulled, approved, or built.
```

That is not a field-presence check. `verify_approval` additionally requires the
reference to be a digest-pinned `cgr.dev/chainguard/python` reference, refuses
any reference containing a tag, requires `platform == linux/amd64`, requires
`base_image_reference == BASE_REPOSITORY@manifest_digest` so the approved object
and the attested subject are the same object, requires `config_digest` and
`sbom_sha256` to be well-formed, requires `sbom_python_package` and
`sbom_python_version` to equal the governed constants **exactly** (a vendor
`-rN` is refused), and pins `attestation_predicate_type`, `attestation_signer`,
`cosign_version` and `cosign_sha256` to compiled-in constants. All passed.

### Contents

| Field | Value |
| --- | --- |
| `base_image_reference` | `cgr.dev/chainguard/python@sha256:4b14dc70f04229cafd97b34ef34b16e1e09bdcac6362097cd5c582dca3eff686` |
| `platform` | `linux/amd64` |
| `manifest_digest` | `sha256:4b14dc70f04229cafd97b34ef34b16e1e09bdcac6362097cd5c582dca3eff686` |
| `config_digest` | `sha256:4090f44b5b3c75835c4f41cb5b3c6efa0cc3abbe66a055a1fd017d60eb6803ff` |
| `sbom_source` | decoded DSSE payload, in-toto Statement v0.1, predicateType `https://spdx.dev/Document` |
| `sbom_sha256` | `eb9acc161dd5eb7622f3f8ca09b8f9a8f679ea7ac0f6ba7d10f48ec0cca228e3` |
| `sbom_python_package` | `python-3.14` |
| `sbom_python_version` | `3.14.6` |
| `cosign_version` | `2.6.0` |
| `cosign_sha256` | `ea5c65f99425d6cfbb5c4b5de5dac035f14d09131c1a0ea7c7fc32eab39364f9` |
| `attestation_predicate_type` | `https://spdx.dev/Document` |
| `attestation_signer` | `https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main` |
| `approved_by` | `cschott` |
| `approved_at` | `2026-08-14T20:26:40Z` |

The approval also answers the README's standing caveat that the registry walk
had been done *without* cryptographic verification and that the operator "must
still run `cosign verify-attestation`". The record pins a cosign version **and
its binary digest**, and names the Chainguard workflow identity as signer — so
the verification the README demanded was performed and recorded.

## 7. Base-reference comparison

Four independent sources, compared over complete values:

| Source | `base_image_reference` |
| --- | --- |
| provisioning evidence | `cgr.dev/chainguard/python@sha256:4b14dc70f04229cafd97b34ef34b16e1e09bdcac6362097cd5c582dca3eff686` |
| approval `base_image_reference` | identical |
| approval `manifest_digest` | `sha256:4b14dc70…` — same digest |
| **image annotation** `…image.base.name` | identical |
| **image annotation** `…image.base.digest` | `sha256:4b14dc70…` — same digest |
| image history, first instruction | `FROM cgr.dev/chainguard/python@sha256:4b14dc70…` |
| `README.md:1083` | `sha256:4b14dc70…` |

And the base's **config digest** `sha256:4090f44b…`, recorded by both the
approval and `README.md:1084`, is present in the same store as a local image ID
— because a pulled image's local ID *is* its config digest.

**`BASE_IMAGE_APPROVAL = PASS`.** The artefact, the approval and the committed
README all name the same base, and that base is physically present.

## 8. SBOM comparison

| Source | `sbom_sha256` |
| --- | --- |
| provisioning evidence | `eb9acc161dd5eb7622f3f8ca09b8f9a8f679ea7ac0f6ba7d10f48ec0cca228e3` |
| approval | `eb9acc161dd5eb7622f3f8ca09b8f9a8f679ea7ac0f6ba7d10f48ec0cca228e3` |

**Exact, full-value match.** This is precisely the cross-check
`verify_production_evidence` performs at `g5-ceremony.sh:1014` — the evidence
must commit the SBOM the approval committed — and it succeeds.

`sbom_python_package` (`python-3.14`) and `sbom_python_version` (`3.14.6`) also
match between evidence and approval exactly, and both equal the governed
constants.

**`SBOM_APPROVAL = PASS`.**

No SBOM *document* was read; only its digest, which is what both records commit
to.

## 9. Final fifteen-field matrix

Strongest available authority for each field. Live-image facts outrank committed
constants where both exist.

| # | Field | Value | Class | Strongest authority |
| --- | --- | --- | --- | --- |
| 1 | `architecture` | `amd64` | **MATCH** | live image `.Architecture` |
| 2 | `base_image_reference` | `…@sha256:4b14dc70…` | **MATCH** | live image `base.name`/`base.digest` annotations; approval; `README:1083` |
| 3 | `containerfile_sha256` | `f543c458…` | **MATCH** | tree at `5fca69d1` and working tree; history instruction correspondence |
| 4 | `evidence_schema_version` | `1` | **MATCH** | `EVIDENCE_SCHEMA_VERSION` |
| 5 | `interpreter_link` | `python3` | **UNVERIFIABLE** | filesystem fact; inspect cannot reach it |
| 6 | `interpreter_path` | `/usr/bin/python` | **MATCH** | `CONTAINER_INTERPRETER`; validator enforces equality |
| 7 | `interpreter_sha256` | `041b9331…` | **UNVERIFIABLE** | filesystem fact |
| 8 | `interpreter_target` | `/usr/bin/python3.14` | **UNVERIFIABLE** | filesystem fact |
| 9 | `oci_image_id` | `5cee2b53…` | **MATCH** | live image `.Id`; CIMP-000001; governed store |
| 10 | `os` | `linux` | **MATCH** | live image `.Os` |
| 11 | `python_version` | `3.14.6` | **MATCH** | approval `sbom_python_version`; `GOVERNED_PYTHON_VERSION` |
| 12 | `sbom_python_package` | `python-3.14` | **MATCH** | approval, exact |
| 13 | `sbom_python_version` | `3.14.6` | **MATCH** | approval, exact |
| 14 | `sbom_sha256` | `eb9acc16…` | **MATCH** | approval, exact |
| 15 | `source_commit` | `5fca69d1…` | **MATCH** | real commit, ancestor of HEAD |

**12 MATCH, 3 UNVERIFIABLE, 0 MISMATCH.**

Three fields moved from UNVERIFIABLE to MATCH — `sbom_sha256` on the approval,
and `architecture`/`os` upgraded from governed constants to the live artefact.
Field 2's authority strengthened from committed prose to the image's own
annotation. **Nothing was reclassified on expectation**, and the count was
derived rather than assumed.

## 10. The interpreter fields stay unverifiable

Fields 5, 7 and 8 describe the image's *filesystem*: whether `/usr/bin/python`
is a symlink, what it points at, and the SHA-256 of the interpreter binary.

`podman image inspect` reports the config blob and storage bookkeeping. It does
not enumerate, read or hash filesystem contents. There is no formulation of
inspect that answers these, and the only mechanisms that would — running the
image or mounting its layers — are both forbidden in this checkpoint and were
not attempted.

They are therefore left **UNVERIFIABLE**. The rule was not weakened to
manufacture a cleaner count.

Field 6 is `MATCH` on a narrower basis worth stating precisely: the evidence's
`interpreter_path` equals the governed `CONTAINER_INTERPRETER` constant, and the
validator enforces that equality. That is agreement between two *records*. It is
not proof the file exists at that path inside the image — which is exactly what
fields 5, 7 and 8 would establish.

**These three become execution-time verification requirements.** The natural
place is the isolated backend test, before first production invoke: a container
that resolves `/usr/bin/python`, reports its link target, and hashes the binary
would close all three against the evidence in one step. Recorded as a G6
requirement, not implemented here.

## 11. Entrypoint relationship

The image supplies **no executable**. `Config.Entrypoint` and `Config.Cmd` are
both absent from the config, and history confirms `ENTRYPOINT []` and `CMD []`
were applied deliberately.

The governed argv contract is `fixed-python-entrypoint-v1`, and the worker
composes the container command as image ID, then `CONTAINER_INTERPRETER`, then
`_container_entrypoint(...)` — that is:

```
/usr/bin/python /kyri/package/main.py
```

With an empty image entrypoint, Podman runs exactly that argv. Nothing is
prepended and nothing is inherited.

Had the entrypoint *not* been cleared, the base's own interpreter entrypoint
would prefix the command and the invocation would become
`/usr/bin/python /usr/bin/python /kyri/package/main.py` — which the Containerfile
comment anticipates in terms, describing it as failing "in a way nobody would
read as a configuration error."

**`BACKEND_MUST_OVERRIDE_ENTRYPOINT = NO`**, for two reasons, neither of them an
assumption:

1. This admitted image carries no entrypoint and no command, proven by inspect.
2. The G5 ceremony **refuses admission** of any image that carries either
   (`verify_production_image`, via `empty_config_list`), and the G5 authority
   suite exercises both refusals as named cases. An image with a baked
   entrypoint cannot become a CIMP, and the store resolves by image ID, so the
   backend cannot be handed a different image than the one admitted.

The invariant is enforced at admission rather than at invoke. Recommended as
defence in depth, not as a correction: pass `--entrypoint ""` explicitly at
create, so the backend's correctness stops depending on a property established
in a different ceremony. Not implemented here.

## 12. Environment

Image `Config.Env` carries two values, both from the Chainguard base:

| Variable | Value | Classification |
| --- | --- | --- |
| `PATH` | `/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin` | base runtime; benign. Not needed to exec, since the interpreter is absolute |
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` | TLS trust store; inert under `network=none`, live the moment networking is granted |

Nothing host-dependent, and — importantly — no `PYTHONPATH`, `PYTHONHOME`,
`PYTHONSTARTUP`, `PYTHONUSERBASE`, `LD_PRELOAD` or `LD_LIBRARY_PATH`. Those are
the variables that would let an image change what a Python entrypoint imports or
links, and none is present.

The adapter already declares a closed set (`CONTAINER_ENVIRONMENT`), stated as
literals and injected as `--env` pairs:

```
LC_ALL=C.UTF-8
PYTHONDONTWRITEBYTECODE=1
PYTHONHASHSEED=0
PYTHONUTF8=1
```

`PYTHONDONTWRITEBYTECODE` is load-bearing against the read-only `/kyri/package`
mount; the other three make execution reproducible.

### The gap, stated precisely

The adapter's comment says the container environment is *"inherited from nothing
— not the host process, not the payload, not the package, not the protocol"*.
That is true of every source it names. It does not cover the **image config**,
and Podman merges `Config.Env` with `--env`. The effective container environment
is therefore six variables, not four.

That is not a defect today: both inherited values are benign, and one is inert
under `network=none`. But nothing currently *asserts* it — `verification.py`
compares the create argv, not the container's resolved environment — so a future
base image could introduce a variable the adapter never declared and no check
would notice.

### Proposed closed environment policy for G6

Not implemented here.

1. Treat the effective set as the union of `CONTAINER_ENVIRONMENT` and the
   image's `Config.Env`, and **enumerate both** in the execution profile.
2. Assert the image contributes exactly `PATH` and `SSL_CERT_FILE` with the
   observed values; refuse on any addition, removal or change.
3. Verify the *resolved* environment inside the container against that closed
   set, rather than verifying only the argv that was intended to produce it.
4. Keep `--env-host` off and never pass a valueless `--env NAME`, both of which
   would import coordinator environment.
5. Refuse outright, at profile build, any `PYTHON*` variable outside the four
   governed ones, plus `LD_PRELOAD` and `LD_LIBRARY_PATH`.
6. Once networking stays `none`, consider clearing `SSL_CERT_FILE` so a later
   grant of networking is a deliberate change rather than an inherited default.

## 13. Container user and privilege

`Config.User = 65532:65532`. **The image does not run as root by default**, and
the field is neither empty nor `0`.

It is also not what the container actually runs as. The worker passes
`--user 1000:1000` explicitly (`CONTAINER_UID`/`CONTAINER_GID`), and profile
verification compares what Podman reports against that. The Containerfile states
this is deliberate — the `USER` line is *"metadata only… so an image inspected
outside Kyri is not mistaken for one that would run as root."*

So the backend **must** continue to set the container UID explicitly. Not because
the image default is unsafe, but because the execution identity is an adapter
decision that must not vary with the image.

### Rootless does not mean unprivileged inside

Two separate questions, and the brief is right to insist on the distinction. A
rootless Podman container can still run as uid 0 *inside* its user namespace,
which would be `root` to the payload. Here it cannot: `--user 1000:1000` is
explicit and verified.

The outer mapping, from `/etc/subuid` and `/etc/subgid`:

```
kyri-capability:200000:65536
```

Under Podman's default single-range rootless mapping, container uid 0 maps to
the host uid of the running user (999, `kyri-capability`) and container uids
1…65536 map onto 200000…265535 — so container uid 1000 lands on host uid
**200999**.

The consequence worth stating: **container uid 1000 is not host uid 1000.** It
is not `cschott`, and it is not the coordinator. The numeric coincidence between
`CONTAINER_UID = 1000` and the coordinator's host uid is exactly that, and it
should not be allowed to look like a relationship — the same class of confusion
as `COORDINATOR_UID = 1000` being mistaken for a Kyri invariant.

The exact mapping should be confirmed from `/proc/self/uid_map` during the
isolated backend test rather than derived, as it is here, from `/etc/subuid`
plus Podman's documented default.

Hardening posture already present at create: `--read-only`,
`--read-only-tmpfs=false`, `--cap-drop ALL`, `--security-opt no-new-privileges`,
`--pids-limit`, `--memory 256m`, `--memory-swap 256m`, and a 16 MiB `/tmp`
tmpfs.

## 14. Networking

No governed authority grants network access:

| Record | Field | Value |
| --- | --- | --- |
| CIMP-000001 | — | no network field exists in the admission schema |
| CPKG-0001 | `resource_requirements` | `{}` |
| CCON-0001 | `resource_requirements` | `{}` |
| CCON-0001 | `effect_class` / `determinism_class` | `computational` / `deterministic` |
| CAPDEF-0001 | — | no network or resource grant |

A `computational`, `deterministic` contract with empty resource requirements
describes work that has no business reaching a network.

This is already implemented rather than merely preferred: `profile.py:51`
compiles in `NETWORK = "none"`, it is part of `governed_policy()`, and the module
is explicit that a profile carrying `network: "host"` is **refused, not
normalised to `none` and run** — *"correcting it would execute something nobody
authorised while reporting success."* `host_network` is separately fixed
`False`.

**`NETWORK_DEFAULT = NONE`**, and it should stay a refusal rather than a
default: a default can be overridden by whatever sets it, and a refusal cannot.
Nothing to implement.

## 15. CIMP-000001 backend usability

Every condition the brief set is met:

| Condition | Result |
| --- | --- |
| Evidence digest valid | **YES** — full-value match, `parse_evidence` passes |
| Exact image present | **YES** — `.Id` matches over 64 hex |
| Base approval matches | **YES** — `--verify-approval` passes; four sources agree |
| SBOM approval matches | **YES** — exact digest match |
| No metadata mismatch | **YES** — all seven governed properties pass; **0 MISMATCH** |

**`CIMP_000001_BACKEND_USABLE = YES`.**

CIMP-000001 is usable as the G6 backend image authority as it stands. No new
image, no CIMP-000002, no re-admission, no retirement, no CPKG or Trust change.
The three unverifiable interpreter facts are a **verification obligation for the
isolated backend test before first production invoke**, not a defect in the
authority and not a blocker to writing the backend.

## 16. Expired Fabric chain

Evaluated read-only against the live records using the released engine, not by
arithmetic alone. `tools/fabric/eligibility.py:459` binds ELIG-7 to `_admitted`,
which returned:

```
ConditionResult(status='unmet', reason='admission-window-expired')
```

and ELIG-6's window predicate (`observed_at <= instant < valid_until`) evaluates
`False`.

| Record | Field | Value | At `2026-08-30T20:00:51-05:00` |
| --- | --- | --- | --- |
| CADV-000003 | `valid_until` | `2026-08-30T16:19:19-05:00` | lapsed by 3h 41m |
| CINST-000002 | `admitted_until` | `2026-08-30T16:19:19-05:00` | lapsed by 3h 41m |

**`CURRENT_PRODUCTION_CHAIN_EXPIRED = YES`.** CINST-000002 is no longer eligible
on both ELIG-6 and ELIG-7.

Expected and safe: production invoke remains unauthorised and both conditions
fail closed. Nothing was renewed. `invoke --preflight` was **not** run — it is
part of the invoke path the brief forbids, and evaluating the engine's own
predicates against parsed records answers the question without going near it.

## 17. Remaining dependency graph and implementation order

The image plane is now closed. Eight items remain, and the reviewer's four
sequencing preferences are all satisfiable simultaneously.

| # | Work | Depends on | Kind |
| --- | --- | --- | --- |
| 1 | Admission bound `admitted_until <= advertisement.valid_until` | — | source + test |
| 2 | Deployment-bound coordinator identity | — | privileged helper |
| 3 | G6 Podman backend | CIMP-000001 (**now usable**) | source + test |
| 4 | Generation 13 packaging | 1, 3 | packaging |
| 5 | Generation 13 install | 4 | production install |
| 6 | Helper / sudoers ceremony | 2 | privileged ceremony |
| 7 | CADV-000004 → CINST-000003 → CROUTE-0003 → CSEL-000002 | 1, 5, 6 | Fabric writes |
| 8 | Invoke preflight, then first production invoke | 7 | operation |

**Recommended order: 1 → 3 → 4 → 2 → 5 → 6 → 7 → 8.**

The reasoning behind the two non-obvious placements:

**Admission bound first (1), and as its own checkpoint.** It is small, has no
dependencies, and must exist before CINST-000003 — which is the very write that
sets the field it guards. Doing it first also lets it ride into Generation 13
rather than forcing a Generation 14.

**Fabric renewal last (7), deliberately.** Every renewed record carries a finite
window, and the current chain expired precisely because it was written before
the execution system was ready. Renewing again before the backend is installed
and the helper ceremony is done would spend a second window the same way. The
expired chain costs nothing while invoke stays unauthorised.

Backend source (3) precedes Generation 13 (4) so one package carries both the
preflight and the backend. Coordinator authority (2) and its ceremony (6)
precede any privileged execution. The isolated backend test belongs with (3),
and is where the three interpreter fields get closed.

Carried unchanged: `ADMISSION_BOUND_REQUIRED_BEFORE_NEW_CINST=YES`,
`COORDINATOR_AUTHORITY_REQUIRED_BEFORE_BACKEND_DEPLOY=YES`, `GEN13_REQUIRED=YES`,
`NEW_IMAGE_REQUIRED=NO`, `NEW_CIMP_REQUIRED=NO`, `NEW_CPKG_REQUIRED=NO`,
`NEW_TRUST_REQUIRED=NO`.

## 18. Production non-mutation

Before and after, by identical measurement:

| Surface | Value |
| --- | --- |
| CIMP-000001 admission | `ecb38d80dd0e9ee444b182811fd556184b085e5e0cec236bf012228f0dc9991b`, one file, no retirement |
| Fabric store | 21 files, `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Installed runtime | 70 objects, `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Routes / sequence / head | CROUTE-0001, CROUTE-0002 / `2` / CROUTE-0002 |
| `kyri-capability` Podman store | inspected read-only; no create, start, mount, tag, build, pull, load or remove |

No image executed, mounted or altered. No container created or started. No
Fabric renewal, no CROUTE, no CSEL, no CINV, no CRES. No stage, no invoke, no
preflight. No runtime or sudoers install. No helper change. No CIMP, Trust or
Evidence mutation. Root Authority not mounted.

The two verifications that executed repository code —
`g5-supply-chain.sh --verify-approval` and the eligibility predicates — ran in
fixture mode against a scratchpad copy and as pure functions over parsed
records. Neither wrote anything, and the approval verifier reports for itself:
*"Nothing was downloaded, installed, pulled, approved, or built."*

No tracked source file modified. `IMPLEMENTATION_COMMIT = NONE`.
`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 19. Findings carried forward

Recorded, not acted on. Items 1–3 carry from G11-AE unchanged.

1. **`5cee2b53…` and `86762793…` are still absent from repository authority.**
   Now joined by a stronger reason to commit them: the base digest, the config
   digest and the SBOM digest are all confirmed and could be recorded alongside,
   so no future audit needs privilege to establish provenance.
2. **`g5-supply-chain.sh:149-151` still hardcodes the superseded 3.14.7
   candidate** as `CANDIDATE_*`, while the governed base is `4b14dc70…` /
   `4090f44b…`.
3. **The G5 test fixtures describe the non-admissible image** (`a3ef70ee…`,
   `84e1f28d…`, `18843222…`).
4. **`README.md:1381-1386` documents twelve approval fields; `APPROVAL_FIELDS`
   requires fourteen.** The prose omits `sbom_python_package` and
   `sbom_python_version`.
5. **Build-tool version is recoverable but ungoverned.** `io.buildah.version`
   records `1.33.7` on the artefact; the closed evidence schema has no field for
   it. Worth a ruling on whether it should.
6. **The effective container environment is six variables, not four** (§12).
7. **Build determinism should be documented as a known property** — G11-AD's
   proof stands.

## 20. Next checkpoint

**G11-AG — the admission dependency bound.** Implement
`admitted_until <= advertisement.valid_until` in `admit_instance`, RED-first,
with a test that refuses an over-long admission. Smallest item on the critical
path, no dependencies, and it must land before CINST-000003 is written.

Then G6 backend source with its isolated test, which is where
`interpreter_link`, `interpreter_sha256` and `interpreter_target` close.

Carried forward unchanged: `WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`,
`ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`, `SEMGREP_RULESET_POLICY=DYNAMIC`,
`ELIG6_HEAD_POLICY_BLOCKS_RENEWAL=NO`, `A3EF_RELATION=DIFFERENT_IMAGE`.
