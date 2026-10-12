# CI coverage contract

What a green GitHub Actions run proves, and what it does not.

This exists because the two answers had drifted apart without anyone deciding
they should. CI was red from 2026-08-11 to 2026-08-30 and stopped at its first
failure, so most of it had not run at all; meanwhile local validation was green
because the machine it runs on is the deployment host. Neither signal meant what
it appeared to.

## The four categories

| # | Category | Proven by |
| --- | --- | --- |
| 1 | Repository-portable validation — source, structure, documentation, static assertions, pure logic | GitHub CI **and** schai |
| 2 | Fixture-based integration — ceremonies and runtimes driven against disposable trees | GitHub CI **and** schai |
| 3 | Live production-host verification — the installed Generation-12 runtime, the governed Fabric and Trust stores | **schai only** |
| 4 | Privileged ceremony verification — operator ceremonies reading their reviewed source from the pinned checkout, as the coordinator identity | **schai only** |

GitHub-hosted runners cover 1 and 2. They must not pretend to cover 3 or 4, and
nothing in this repository should be arranged to make them appear to.

## What green GitHub CI proves

All 98 steps of the `Static validation` job executed. Every portable and
fixture-based suite passed. ShellCheck passed over the same file list a
developer lints, via the same script. Semgrep found exactly the findings a
reviewer has approved and nothing else.

## What remains proven only by schai

Nineteen suites, enumerated with their reasons in `tests/host-only.manifest`
and published to every CI run's job summary. They fall into three groups:

- **Pinned ceremony** — the suite drives an operator ceremony that pins
  `REPOSITORY=/opt/schott-platform` and reads its reviewed source with `git -C`
  as the repository owner. A ceremony that accepted whatever checkout it was
  handed would no longer be proving what it claims, so the pin is not relaxed
  for a runner.
- **Installed runtime** — the suite reads `/usr/lib/kyri/python`, which exists
  only where Generation 12 is installed.
- **Coordinator identity** — the suite builds a launch record that the
  production code authenticates by owner against the pinned `COORDINATOR_UID`.
  A test cannot fabricate that ownership without being that identity.

One further suite requires a filesystem whose UUID the production observation
helper can resolve through `/dev/disk/by-uuid`, which answers for a real block
device and not for a runner's ephemeral workspace.

## How a host-only suite behaves

It declares its preconditions through `tests/lib/host-only.sh`. Where they hold
— on schai — it runs in full, unchanged. Where they do not, it prints one
machine-readable `HOST_ONLY_SKIP` line naming itself and what was missing, and
exits 0 so the rest of the pipeline runs.

Three properties make that safe:

1. **The decision comes from the preconditions, never from a flag.** There is no
   `CI=true`, no `SKIP_HOST_TESTS`, no `--force`. A machine with the production
   layout runs these tests and cannot opt out. An environment variable that
   turned off production checks would eventually be set on the production host.
2. **A skip is not a pass.** `tests/host-only.manifest` names every host-only
   suite with a reason; `tests/test-static.sh` asserts the manifest and the
   suites that source the helper match in both directions, so a suite cannot
   become host-only quietly and a stale entry cannot linger; and CI publishes
   the list to its job summary, so a green run cannot be mistaken for coverage
   it does not have.
3. **The local validator is unaffected.** `tools/dev/run-validation.sh` runs on
   schai, where every precondition holds, so all nineteen execute there. Quick
   and full totals are unchanged by any of this.

## Semgrep

Semgrep reports everything it finds and
`tools/dev/check-semgrep-findings.py` adjudicates against
`.semgrep-exceptions.json`. An exception matches only when rule id, path, line
and the file's current sha256 all agree, so it cannot broaden, and an exception
that matches nothing fails as loudly as an unapproved finding.

**Green Semgrep means: the findings are exactly the reviewed set.** It does not
mean zero findings.

One caveat is inherent and is not solved here. The Semgrep image is pinned by
digest, but `--config auto` fetches its ruleset from the registry at run time.
The rules that produce a green result today are not the rules that will run
tomorrow, so a commit can stay identical while the gate moves underneath it.
See the G11-Z6 report for the pinned-versus-dynamic analysis and the
recommendation.

## Adding a suite

If it needs nothing but the repository, it is category 1 or 2: add it to
`.github/workflows/ci.yml` and `tools/dev/run-validation.sh` and it runs
everywhere.

If it needs the installed runtime, a governed store, the pinned checkout or the
coordinator identity, it is category 3 or 4: declare the precondition through
`tests/lib/host-only.sh` and add it to `tests/host-only.manifest` with a reason.
`test-static.sh` will fail until those two agree.

Do not make a host-only suite pass on a runner by relaxing what it checks. The
point of the split is that the runner never claims what only schai can prove.
