# Production capability execution image — build and admission

**Nothing in this repository builds, pulls, loads, or admits this image.** Every
step below is performed by an operator. Building is gate **G5**; admitting the
resulting digest as a `CIMP` is a separate governed step after it.

Governed by [the first adapter design](../../docs/superpowers/specs/2026-08-11-first-adapter-design.md)
§9 and §27, and the G4 image ruling of 2026-08-12.

## What the image is

A minimal Python runtime and nothing else: standard library only, no shell, no
package manager, no `pip`, no compiler or toolchain, no `sudo`, no SSH, no
`curl` or `wget`, and nothing general-purpose. §27 requires that of the **final
runtime image**; it does not forbid a build stage from carrying tooling, and for
this image no build stage is needed at all — the base already is the runtime.

| Property | Value |
|---|---|
| Base family | minimal Chainguard Python runtime (`cgr.dev/chainguard/python`) |
| Governed Python | **3.14.6** |
| Interpreter path | `/usr/bin/python` |
| Image default user | `65532:65532` (metadata only) |
| Execution identity | `1000:1000`, enforced by Podman at create — never by the image |
| Mount destinations | `/kyri/package` ro · `/run/kyri/input/payload` ro · `/kyri/output` rw |

The interpreter is `/usr/bin/python` because the base configures it there. T12's
`CONTAINER_INTERPRETER` was corrected to match at the G4 ruling; the host-side
`WORKER_INTERPRETER` is a different thing and is unchanged.

## Base pinning

The `BASE_IMAGE` build argument has **no default**. Supply a digest-pinned
reference of exactly this form:

```
cgr.dev/chainguard/python@sha256:<64 lowercase hex characters>
```

A tag may be used during provisioning **discovery only**, to find a candidate
digest. It must never reach the build: the vendor's tags float, so a tag records
an intention rather than an artefact.

Refuse anything that is not the digest form above — including a tag, a
`:latest`, a bare repository name, a digest of the wrong length, or a reference
to a different repository.

## Candidate admission — all three must agree

Verify independently, and admit only on unanimous agreement:

1. **OCI base digest** equals the expected candidate digest.
2. **SBOM** reports the governed runtime package **`python-3.14`** at
   **3.14.6** — the package as Chainguard's signed SPDX actually names it. A
   vendor revision (`3.14.6-r4`) is expected and is normalised to the upstream
   patch before it is recorded; `cpython v3.14.6` is the upstream source record
   and is not the governed package.
3. **`/usr/bin/python` reports 3.14.6** when asked for its version.

If any of the three disagree, **do not admit the image.** A distribution package
revision (`-rN`) may differ as the vendor rebuilds the same upstream Python;
that is expected and acceptable, because the OCI digest identifies the exact
artefact while `3.14.6` fixes the governed upstream semantics.

## Interpreter resolution — symlinks are allowed, with proof

`/usr/bin/python` **may** be a symlink. The whole image filesystem — the link
and its target together — is committed by the immutable OCI digest, which is
stronger evidence than a rule forbidding symlinks would be.

At admission, verify the link:

- resolves entirely **inside** the image rootfs;
- traverses nothing outside the image;
- terminates at a **regular executable file**;
- reports **Python 3.14.6**.

## Provisioning evidence to record

Record all of the following with the admission decision:

- the OCI image digest;
- the `/usr/bin/python` link value, if it is a symlink;
- the resolved target path;
- the **SHA-256 of the resolved interpreter file**;
- the reported Python version (`3.14.6`);
- the relevant SBOM Python package and version.

## Final-image absence checks

Prove absent from the final image: any package manager (`apk`, `apt`, `apt-get`,
`dpkg`, `dnf`, `yum`, `pip`, `pip3`), any shell (`sh`, `bash`, `dash`, `ash`,
`busybox`), any compiler or toolchain (`cc`, `gcc`, `ld`, `make`), `sudo`, `su`,
SSH (`ssh`, `sshd`, `scp`), and `curl` or `wget`.

## CIMP admission

Admission is an **operator procedure, not an automated step.** Nothing in the
runtime mints a `CIMP`, writes the authority set, or advances a `CGEN`; the
execution runtime cannot modify the allowlist at all, and there is no pull
during invocation — a digest absent from the `kyri-capability` rootless store is
`execution_image_unavailable`, never a fetch.

After the checks above pass, the operator:

1. loads the built image into the `kyri-capability` rootless store;
2. records the digest and the evidence above;
3. admits the digest as a `CIMP` through the governed provisioning path;
4. confirms the digest is present in the store before any execution is
   authorised.

## Still open at G4/G5 — this image does not solve it

**Per-`CINV` output byte and inode quota** (design §34) remains unresolved.
Nothing bounds what a workload writes into the read-write `/kyri/output` bind
mount during its 30 seconds. That is a **host storage** decision — XFS project
quotas require filesystem quota configuration and root-side project assignment —
and no part of this image definition addresses it. Do not read the image
contract as covering it.
