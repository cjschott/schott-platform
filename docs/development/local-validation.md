# Local Validation

Every check that CI runs is reproducible on a workstation. **Passing local
validation should produce the same result as CI** — the workflows in
`.github/workflows/` invoke the same commands and tools documented here and
invent no CI-only behavior.

All commands run from the repository root. None of these validations require
`schai`, a running deployment, or a real secret — Compose is only *rendered*,
using the sanitized `ai/.env.example` template.

## One command

```bash
tools/dev/run-validation.sh
```

Twenty steps in a fixed order, stopping at the first failure:

| # | Step |
|---|---|
| 1 | Toolchain check |
| 2 | Shell syntax (`bash -n`) over `scripts/`, `tests/`, `tools/dev/` |
| 3 | ShellCheck, pinned `0.9.0` |
| 4–5 | Static repository and documentation assertions |
| 6 | Platform model validation |
| 7–10 | Evidence validator, collector framework, initial collectors, knowledge orchestrator, developer experience |
| 11–12 | `validate_evidence.py`, `validate_plugins.py` |
| 13–15 | Collector CLI `list` and `validate`, observation CLI `--help` |
| 16 | Three Docker Compose configuration renders |
| 17 | Whitespace (`git diff --check`) |
| 18 | Tracked Python bytecode |
| 19 | Runtime evidence backstop |
| 20 | `platform-model` mutation backstop |

It preserves the exit code of whatever failed, so the status you get is the
status of the thing that broke rather than a flattened `1`.

## Quick mode

```bash
tools/dev/run-validation.sh --quick
```

**Quick mode omits exactly four things, and nothing else:**

- `tests/test-platform-model.sh` — 848 assertions, the slowest suite
- `tests/test-initial-collectors.sh` — builds temporary git repositories
- `tests/test-knowledge-orchestrator.sh` — builds temporary evidence stores
- the three Docker Compose renders — each spawns the compose binary

It **still runs** shell syntax, ShellCheck, both static suites, the evidence
validator, the collector framework, the developer experience suite, both Python
validators, all three CLI checks, the bytecode check, the whitespace check, and
both backstops.

Quick mode is for a tight edit loop. **It is never sufficient before pushing.**
It prints its own summary of what it omitted, so a passing quick run cannot be
mistaken for a full one.

## Local CI wrapper

```bash
tools/dev/run-local-ci.sh            # strict, full validation
tools/dev/run-local-ci.sh --report   # parity summary only, runs nothing
```

Runs the same validation in `--strict` mode and prints a CI parity summary.

Strict mode matters here. Tolerating a tool-version warning is reasonable in an
edit loop, but this script's claim is "this is what CI will do" — making that
claim while running a different PyYAML build would be false, so a version
mismatch fails it.

## PyYAML fails closed

Five suites depend on PyYAML for their behavioural blocks. Every one of them
**fails closed**: if PyYAML cannot be imported, the suite exits non-zero and
names the fix.

```
ERROR PyYAML is required for test-platform-model.sh and is not importable.
A skipped behavioural block must never report success, so this is a failure.
Install the pinned version:

    python3 -m pip install --require-hashes -r requirements-ci.txt
```

Before v0.7.5 these suites printed `SKIP` and exited `0`. That is the failure
mode this behaviour exists to remove: a green run that verified almost nothing
is worse than no run at all, because it actively tells you your change is safe.

CI is unaffected — it installs the hash-pinned dependency and verifies it before
any suite runs — so this changes only what happens on a machine without PyYAML.

Confirm the behaviour without uninstalling anything:

```bash
SHIM=$(mktemp -d)
printf 'raise ImportError("simulated")\n' > "$SHIM/yaml.py"
PYTHONPATH="$SHIM" bash tests/test-platform-model.sh   # exits 1
rm -rf "$SHIM"
```

## What validation will not do

- contact a remote host, or call any GitHub API
- install, upgrade, or remove a package
- start, stop, or inspect a platform container, volume, or network
- read the real environment file (only `*.env.example` templates are used) or any secret
- persist evidence, or write anything into `platform-model/`
- modify the host in any way

The only container it may start is the pinned ShellCheck image: ephemeral,
`--network none`, repository mounted read-only.

Steps 19 and 20 prove the last two claims after the fact — they fail the run if
generated records were committed or if any suite left `platform-model`
modified.

## Running the pieces by hand

The wrapper is a convenience, not a requirement. Each check is an ordinary
command:

```bash
bash -n scripts/*.sh
bash -n tests/test-static.sh
bash -n scripts/*.sh tests/*.sh tools/dev/*.sh   # or all at once
tools/dev/run-shellcheck.sh
bash tests/test-static.sh
python3 tools/platform_model/validate_evidence.py --root platform-model
docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
```

## Security tooling

These mirror the dedicated security workflows. They are **optional locally**
(install only what you need) but **required in CI**, and none of them is covered
by `run-validation.sh` — see the gap list in `run-local-ci.sh --report`.

### ShellCheck — `shellcheck.yml`

Now covered by `tools/dev/run-shellcheck.sh`, which pins version `0.9.0` to
match CI and needs no host package. To run it directly:

```bash
shellcheck scripts/*.sh tests/*.sh tools/dev/*.sh
```

Warnings are not suppressed globally. If a specific finding is a false positive,
add a scoped `# shellcheck disable=SCxxxx` with a justification in the script.

### Gitleaks — `gitleaks.yml`

```bash
gitleaks detect --source . --redact --verbose
```

Repository mode; nothing is allowlisted by default. A verified leak fails.

### Trivy — `trivy.yml`

```bash
trivy fs --severity HIGH,CRITICAL --exit-code 1 --skip-dirs backups,logs,models,data .
```

Filesystem scan of the repository for HIGH/CRITICAL findings. No image scanning
in this baseline.

### Semgrep — `semgrep.yml`

Semgrep is pinned to **version 1.171.0** by an immutable container digest. Run
the exact same image locally:

```bash
docker run --rm -v "$PWD:/src" -w /src \
  semgrep/semgrep:1.171.0@sha256:bdf7013b2c3634a487671158da77c554f531742326b543a9464d2adf6c433ac8 \
  semgrep scan --config auto --error
```

Default security rules; findings fail the run. (If you have Semgrep installed
natively at the same version, `semgrep scan --config auto --error` is
equivalent.)

### CodeQL — `codeql.yml`

CodeQL scans the repository's **GitHub Actions workflows** (CodeQL language
`actions`) for issues such as unpinned actions, script-injection risks, and
excessive permissions. CodeQL has **no analyzer for Bash/shell**, so the shell
scripts themselves are covered by **ShellCheck** and **Semgrep** above, not by
CodeQL.

CodeQL is **GitHub-hosted** analysis that runs in the CI environment; it has no
simple equivalent local command in this baseline. Review its findings in the
repository's code-scanning results rather than locally.

### Dependabot — `.github/dependabot.yml`

Dependabot is **GitHub-hosted** and also has no local command. It runs monthly
and opens grouped pull requests for GitHub Actions pins (in `.github/workflows`)
and for the Docker Compose image references under `ai/`. Review and merge those
PRs manually — nothing here auto-merges.

## Required vs optional summary

| Check | Tooling | Local | CI workflow |
|---|---|---|---|
| Everything below, in order | `tools/dev/run-validation.sh` | Required | `ci.yml` |
| Shell syntax | Bash | Required | `ci.yml` |
| Static assertions | Bash (+ Docker for Compose parts) | Required | `ci.yml` |
| Compose render | Docker Compose v2 | Required | `ci.yml` |
| ShellCheck | pinned `0.9.0`, container or host | Required | `shellcheck.yml` |
| Gitleaks | `gitleaks` | Optional | `gitleaks.yml` |
| Trivy (fs) | `trivy` | Optional | `trivy.yml` |
| Semgrep | `semgrep` 1.171.0 (pinned) | Optional | `semgrep.yml` |
| CodeQL (Actions) | GitHub-hosted (no local equiv.) | n/a | `codeql.yml` |

Run `tools/dev/run-validation.sh` before every push; run the optional security
tools when changing scripts, configuration, or dependencies.

## Related

- [Getting started](getting-started.md)
- [Toolchain](toolchain.md)
