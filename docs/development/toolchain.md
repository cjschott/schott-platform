# Toolchain

Every tool version this repository depends on is pinned in one file:
[`tools/dev/versions.env`](../../tools/dev/versions.env).

One file, because a second copy of a version string is a second place to forget
to update.

## Pinned versions

| Variable | Value | Kind | Evidence |
|---|---|---|---|
| `SHELLCHECK_VERSION` | `0.9.0` | CI-aligned, exact | CI log, ShellCheck run `30723148728`: `version: 0.9.0` |
| `SHELLCHECK_IMAGE` | `koalaman/shellcheck:v0.9.0` | exact | Provides the pinned version without a host package |
| `PYTHON_MIN_VERSION` | `3.12` | minimum | `ubuntu-24.04` runner; schai reports `3.12.3` |
| `PYYAML_VERSION` | `6.0.3` | exact | `requirements-ci.txt`, hash-pinned |
| `DOCKER_COMPOSE_MIN_VERSION` | `2.0.0` | minimum | `CLAUDE.md` mandates Compose v2 |
| `DOCKER_COMPOSE_HOST_OBSERVED` | `5.3.1` | host-observed | schai, recorded not enforced |
| `GIT_MIN_VERSION` | `2.43.0` | host-observed, enforced as minimum | schai; `ubuntu-24.04` ships 2.43.x |

## What each kind means

- **exact** — must match precisely. A different version is an error.
- **minimum** — this version or newer is fine.
- **CI-aligned** — must match what a workflow actually runs.
- **host-observed** — recorded from `schai`. It is what has actually been
  validated, not a theoretical floor.

The distinction matters when a check fails. A `minimum` failure means upgrade;
an `exact` failure means match the pin, because newer is not automatically
better when the goal is producing identical results to CI.

## Why ShellCheck is pinned when CI does not pin it

The workflow runs whatever ShellCheck `ubuntu-24.04` ships. That version was
observed as `0.9.0`, and the manifest records it.

Pinning locally against an unpinned CI looks backwards, but the alternative is
worse: without a pin, a developer with a newer ShellCheck sees findings CI does
not report, or misses findings CI does. Recording the observed version makes
that divergence visible instead of silent.

If the runner image updates ShellCheck, CI will print a different version. The
fix is to update the manifest with the new observed value — not to remove the
pin.

## Why git is pinned at the host version

`2.43.0` is higher than this repository strictly needs; every git feature the
suites use is far older. It is recorded because it is the only version this
repository has actually been validated against, and a lower bound nobody has
tested is a guess with a number on it.

## The PyYAML divergence

`requirements-ci.txt` pins `pyyaml==6.0.3` with published sha256 hashes, and CI
installs it with `--require-hashes`.

A developer machine often carries a distro build instead — `schai` currently
has `6.0.1`. Both parse this repository's YAML identically, and every suite
passes on either.

That is handled honestly rather than by pretending it does not exist:

- `check-toolchain.sh` reports it as a **warning**. Failing an edit loop over a
  patch-level difference that changes no result would be obstructive.
- `check-toolchain.sh --strict` reports it as an **error**.
- `run-local-ci.sh` always uses `--strict`, because that script's claim is
  "this is what CI will do", and making that claim while running a different
  library build would be a false claim.

To match CI exactly:

```bash
python3 -m pip install --require-hashes -r requirements-ci.txt
```

## Updating a pin

1. Find the evidence — a CI log, a release page, or the host.
2. Update `tools/dev/versions.env` **and** the comment recording where the
   value came from.
3. If PyYAML changed, update `requirements-ci.txt` with the new version and its
   published hashes. Never hand-edit a hash.
4. Run `tools/dev/run-validation.sh`.

`tests/test-developer-experience.sh` asserts that the manifest's PyYAML version
equals the one in `requirements-ci.txt`, so those two cannot drift apart
unnoticed.

## Related

- [Getting started](getting-started.md)
- [Local validation](local-validation.md)
