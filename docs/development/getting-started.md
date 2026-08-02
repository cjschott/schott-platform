# Getting Started

Setting up a machine to develop and validate the Schott Platform repository.

## Prerequisites

You need `python3`, `git`, Docker with Compose v2, and a way to run ShellCheck
0.9.0. Exact versions and why each is pinned are in
[toolchain.md](toolchain.md).

## 1. Check what you have

```bash
tools/dev/check-toolchain.sh
```

Read-only. It reports each tool with `ok`, `warning`, or `ERROR`, and every
failure names the command that fixes it.

A `warning` means validation will run but your machine differs from CI in a way
worth knowing about — most commonly a distro PyYAML build that is not the
hash-pinned one CI installs. Warnings become errors under `--strict`, which is
what `run-local-ci.sh` uses.

## 2. See what is missing

```bash
tools/dev/bootstrap.sh
```

**This is a dry run and changes nothing.** It prints exactly what is missing and
the exact command that would install it. Nothing is installed, no service is
touched, and the host is not modified.

**Nothing is ever installed without your explicit approval.** There is no
implicit install path and no prompt that installs on a default answer.

## 3. Install, if you choose to

Either copy the printed commands and run them yourself, or:

```bash
tools/dev/bootstrap.sh --apply
```

`--apply` installs **only** the host packages listed in the dry run, using
`apt-get`. It never installs anything else, and it never runs the non-package
steps — those you always run yourself, so the change stays deliberate.

`--apply` does not, and will not:

- start, stop, or reconfigure any Docker container, volume, or network
- change firewall rules or SSH configuration
- modify `ai/.env` or any secret
- touch a running platform service

If you would rather not use `--apply` at all, that is a supported workflow. The
dry run gives you everything you need to do it by hand.

## 4. Validate

```bash
tools/dev/run-validation.sh
```

One command, twenty steps, everything CI runs. Details and the faster
`--quick` mode are in [local-validation.md](local-validation.md).

## 5. Optional: pre-commit hooks

```bash
python3 -m pip install pre-commit
pre-commit install
```

Optional and off by default. The hooks are fast checks only — syntax,
ShellCheck, whitespace, bytecode, and the static suite. The full suite is
deliberately not run on every commit: a slow hook gets bypassed with
`--no-verify`, and a check that is routinely bypassed protects nothing.

Every hook is `repo: local` and calls a script already in this repository. No
external hook repository is referenced.

## Troubleshooting

**"PyYAML is required ... and is not importable"** — a suite refused to run
rather than skipping. Install the pinned version:

```bash
python3 -m pip install --require-hashes -r requirements-ci.txt
```

**"No ShellCheck 0.9.0 execution path"** — make the pinned image available:

```bash
docker pull koalaman/shellcheck:v0.9.0
```

**"host shellcheck is X but 0.9.0 is pinned"** — a different ShellCheck version
can report different findings, so a mismatch is refused rather than accepted.
Use the container image, which needs no host package.

**Validation stops partway** — that is intended. It stops at the first failure
and tells you which step and what exit code, so the first error you read is the
real one.

## Related

- [Toolchain](toolchain.md)
- [Local validation](local-validation.md)
- [Platform roadmap](../platform-roadmap.md)
