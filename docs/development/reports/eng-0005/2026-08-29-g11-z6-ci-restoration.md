# ENG-0005 G11-Z6 — GitHub CI restoration and exact Semgrep exception governance

**Date:** 2026-08-29 (CI runs cross into 2026-08-30 UTC)
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `fb0124853fd5f1eec5b26621a97e3d07ca4c503e`
**Implementation commits:** `3289e65`, `b4e31f9`, `79d855d`, `36a1e7e`, `f1ef052`, `cefaf74`

GitHub CI is green: all 98 steps of the `Static validation` job executed, none
failed, none went unrun. Semgrep and ShellCheck are green. The nineteen suites
that can only be proved on the deployment host are enumerated, published to
every run's job summary, and still run in full on schai. Production was not
touched.

---

## 1. Starting authority

| Check | Observed |
| --- | --- |
| HEAD | `fb0124853fd5f1eec5b26621a97e3d07ca4c503e`, clean, matching origin |
| G11-Z3 / Z4 / Z5 reports | all three present, all ancestors of HEAD |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Local quick / full | 78/78, 101/101 |

## 2. The 63-step blind spot, and how it was measured

The CI job stops at its first failure, so from 2026-08-11 the tail was dark: 63
of 97 steps had not run. Discovering what was in there by pushing and reading
one new failure per round would have taken dozens of cycles.

Instead the runner was reproduced locally: a real clone with full history, at
the runner's own path (`/home/runner/work/schott-platform/schott-platform`),
owned by an unprivileged uid, with CI's hash-pinned PyYAML and the same
ShellCheck, and no production layout.

**39 of 85 suites failed there while all 85 pass on schai.** Two harness errors
were found and corrected first, and both mattered: the container initially ran
as root, which alone accounted for 17 spurious failures, and it mounted the
checkout at the wrong path, which made nine suites report a mismatch that a real
runner reports differently.

The simulator is a filter, not an oracle. Three of its residual failures were
its own artefacts, confirmed by the real runner passing them; and it *missed*
two real failures that only the runner showed. Both facts are recorded below
rather than smoothed over.

## 3. Pinned-path consumers and the portable / host-only split

Every consumer of a pinned production path was classified before anything was
edited.

**Class B — host-only (19 suites).** Enumerated with reasons in
`tests/host-only.manifest`.

| Group | Count | Why it cannot run on a runner |
| --- | --- | --- |
| Pinned ceremony | 15 | The ceremony pins `REPOSITORY="/opt/schott-platform"` and reads its reviewed source with `git -C` as the repository owner via `runuser`. `--fixture` prefixes every host path — library root, transaction root, evidence, sudoers, authority — but deliberately **not** `REPOSITORY`. |
| Installed runtime | 1 | Reads `/usr/lib/kyri/python`, which exists only where Generation 12 is installed. |
| Coordinator identity | 3 | Builds a launch record the production code authenticates by owner against the pinned `COORDINATOR_UID`. |

The production pin was not weakened, not defaulted, not inferred from `$PWD`,
and the runner workspace was not symlinked into `/opt/schott-platform`.

**Class A — portable, failing for a fixable reason.** Four suites failed on a
runner for reasons unrelated to their subject; each was corrected in the harness
without touching what it asserts. They are §7.

## 4. CI coverage contract

Written to `docs/development/ci-coverage-contract.md`, which is the answer to
"what does green GitHub CI prove?" and "what remains proven only by schai?".

Categories 1 (repository-portable) and 2 (fixture-based integration) are proved
in both places. Categories 3 (live production host) and 4 (privileged ceremony)
are proved on schai only, and CI is arranged so it cannot appear to prove them.

## 5. Initial RED

| Evidence | Before |
| --- | --- |
| Runner simulation | 39 of 85 suites failing |
| Real CI, run 33276320778 | 33 steps ok, 1 failed, 63 never run |
| Pinned-ceremony suites | hard `exit 1`: `this checkout is … but the ceremony pins /opt/schott-platform` |
| Semgrep | 1 blocking finding, job red |
| ShellCheck | green as of G11-Z5 |

## 6. The host-only mechanism

`tests/lib/host-only.sh` provides four declarations: a path precondition, a
pinned-checkout precondition, a coordinator-identity precondition, and an
observable-filesystem precondition. A suite that cannot run prints one
machine-readable `HOST_ONLY_SKIP` line naming itself and what was missing, then
exits 0.

Three properties keep this from becoming a bypass:

1. **The decision comes from the preconditions, never from a flag.** There is no
   `CI=true`, no `SKIP_HOST_TESTS`, no override of any kind — deliberately, because
   a switch that disables production checks eventually gets set on the
   production host. A machine with the layout runs the tests and cannot opt out.
2. **A skip is not a pass.** `test-static.sh` asserts the manifest and the suites
   that source the helper match **in both directions**, so a suite cannot become
   host-only quietly and a stale entry cannot linger; every entry must carry a
   non-empty reason; and CI publishes the list to its job summary
   (`host-only suites declared: 19`).
3. **schai is unaffected.** Every precondition holds there, so all nineteen run
   in full. Quick and full totals are unchanged.

`test-static.sh` also gained a stricter rule for sourced libraries — no shebang
they cannot use, no shell options set in the caller's shell, not executable —
because the alternative was letting `tests/lib/` opt out of the existing
shell-script invariant. `run-shellcheck.sh` lints `tests/lib` too.

## 7. Every newly exposed failure and its disposition

Real CI advanced 33 → 59 → 79 → 90 → 92 → 98 across five pushes.

| # | Suite | Root cause | Disposition |
| --- | --- | --- | --- |
| 1 | 15 pinned-ceremony suites | ceremony pins `/opt/schott-platform`; `--fixture` does not prefix `REPOSITORY` | host-only |
| 2 | generation-12 packaging | reads the installed runtime | host-only |
| 3 | transition-action, profile-transport, g61-verification | `COORDINATOR_UID = 1000`; the fixture launch record must be owned by it | host-only (identity) |
| 4 | launch-bridge | `/data/kyri/capability-handoff` absent | assertion runs only where the root exists |
| 5 | admin, image, quota, provisioning | `/etc/sudoers.d` is 0755 on schai, 0750 on the runner; `Path.exists()` raises EACCES | unreadable recorded as distinct from absent |
| 6 | 18 snapshot helpers | `except FileNotFoundError` only; `os.lstat` on the unreadable sudoers path raised | `PermissionError` recorded as `"unreadable"` |
| 7 | launch-cli | the backing-store fixture asks the production helper for the filesystem UUID; `/dev/disk/by-uuid` answers for a block device, not a runner workspace | host-only (observable filesystem) |
| 8 | initial-collectors, developer-experience | **simulator artefacts** — missing tooling in the container | no change; both already passed on the real runner |

Two entries deserve their own note.

**#3 is a latent fragility, not just a CI problem.** Those three suites pass on
schai only because the operator account happens to be uid 1000, which is
`COORDINATOR_UID`. They have relied on that coincidence silently since they were
written. Proved by running them in the container as uid 1001 (all three fail)
and again as uid 1000 (all three pass), with nothing else changed. The
dependency is now declared rather than incidental. Whether the deployment should
guarantee that identity, rather than inherit it, is worth a reviewer's attention
and is not decided here.

**#5 and #6 were both found by sweeping, and the first sweep missed #6** —
its path list and its existence check sit on different lines, so a grep for
"sudoers" near `.exists()` did not see it. The second sweep looked for the
narrow `except` instead and found all eighteen at once.

## 8. Complete 97-step traversal

Run **33287751618**, commit `cefaf74d3d821b48b6007ee1f1bf6777a6b8efe3`:

```
job=Static validation  conclusion=success
total=98  ok=98  failed=0  notrun=0
```

`CI_STEPS_TOTAL=98` — the brief said 97; the job gained one step, the host-only
declaration. `CI_STEPS_EXECUTED=98`, `CI_HOST_ONLY_SKIPPED=19`,
`CI_PORTABLE_FAILED=0`. The dark tail has been observed in full.

## 9. Host-only skip inventory

Nineteen, from `tests/host-only.manifest`, each printed by the run:

Pinned ceremony — `test-artifact-authority.sh`,
`test-capability-execution-g5-authority.sh`,
`test-capability-execution-g5-build-context.sh`,
`test-capability-execution-g5-ceremony.sh`,
`test-capability-execution-g5-preflight.sh`,
`test-capability-execution-generation5-installer.sh` through
`test-capability-execution-generation12-installer.sh` (eight),
`test-fabric-evidence-authority.sh`.

Installed runtime — `test-capability-execution-generation12-packaging.sh`.

Coordinator identity — `test-capability-execution-g61-verification.sh`,
`test-capability-execution-profile-transport.sh`,
`test-capability-execution-transition-action.sh`.

Observable filesystem — `test-capability-execution-launch-cli.sh`.

## 10. Semgrep — the finding, and why it is a false positive

```
tools/capability/package_resolution.py:466
python.lang.security.audit.insecure-file-permissions
"These permissions `_STAGING_MODE` are widely permissive … A good default is `0o644`"
   466┆ os.chmod(staging, _STAGING_MODE)
```

`_STAGING_MODE = 0o700`: owner only, nothing to group, nothing to other. The
rule reads the *name* of the constant rather than its value. Its proposed
`0o644` would be strictly worse here — world-readable, and unusable for a
directory, which needs the execute bit to be traversed at all. The call site is
`_abandon()`, which leaves an unpublished staging tree readable to the operator
who owns it and to nobody else.

**The code is the more secure of the two.** It is on the execution path, which
is why it was examined rather than waved through.

## 11. The exception mechanism

`--exclude-rule` exists in Semgrep 1.171.0 but is repository-wide for that rule,
and this codebase names *every* file mode as a constant (`0o500`, `0o400`,
`0o700`), so excluding the rule would blind it everywhere it could ever be
useful. An inline `nosemgrep` was attempted in G11-Z5 and rejected by local
validation: `package_resolution.py` is an installed Generation-12 object whose
digest is authority, and a comment changes it.

Semgrep now reports everything (`--json`) and
`tools/dev/check-semgrep-findings.py` adjudicates against
`.semgrep-exceptions.json`. An exception matches only when **rule id, path, line
and the file's current sha256** all agree. The Semgrep fingerprint was
considered as the anchor and rejected: it reports `requires login` without an
account, so the source digest is both available and stricter.

## 12. Proof the exception cannot broaden

Ten failure modes exercised; each refuses:

| Mutation | Result |
| --- | --- |
| Same rule fires in another file | `UNAPPROVED finding` |
| A different rule fires in the approved file | `UNAPPROVED finding` |
| The approved finding moves to another line | refused, names both lines |
| An extra unapproved finding appears | `UNAPPROVED finding` |
| The approved finding disappears | refused — a stale exception must be removed deliberately |
| Semgrep reports an `error`-level error | refused |
| Semgrep output does not parse | refused, "refusing to treat that as clean" |
| The approved file changes by one byte | refused, prints both digests |
| The registry is missing | refused |
| A justification is empty | refused |

Parse notices that Semgrep itself downgrades to `warn` — four of them, on
generated shell and on `ci.yml` — do not fail the gate, because a warning that
a file was partially read is not a scan that errored.

## 13. Semgrep ruleset reproducibility

`SEMGREP_RULESET_POLICY = DYNAMIC` today, and that is a real exposure: the image
is pinned by immutable digest, but `--config auto` fetches its ruleset from the
registry at run time (`registry usage is True` in every run's log). A commit can
stay byte-identical while the security gate moves underneath it. The 1074 rules
that produced today's green are not guaranteed to be tomorrow's.

**Recommendation: PINNED, as a separate reviewer-visible change.** Pinning
buys reproducibility — the property that matters most immediately before a first
production invoke, where "nothing changed" must mean nothing changed. It costs
currency: newly published rules stop arriving until someone updates the pin,
which is a maintenance commitment, and a pin that is never refreshed is a gate
that quietly stops improving.

It is not done here because changing the ruleset source would materially alter
security coverage, which the brief reserves for a separate decision. Meanwhile
the exception registry limits the blast radius: a registry change that produces
new findings fails closed rather than passing.

**What current Semgrep green means, exactly:** with the registry ruleset as of
2026-08-30 and Semgrep 1.171.0, the scan produced one finding, and that finding
is the reviewed one at the reviewed digest. It does not mean zero findings, and
it does not mean the same rules will run next time.

## 14. Current-head cloud proof

Commit `cefaf74d3d821b48b6007ee1f1bf6777a6b8efe3`:

| Workflow | Run | Conclusion |
| --- | --- | --- |
| CI | 33287751618 | **success** — 98/98 steps, 0 failed, 0 unrun |
| Semgrep | 33287751612 | **success** — `1 finding(s), all 1 reviewed and approved` |
| ShellCheck | 33287751611 | **success** |
| CodeQL | 33287751692 | success |
| Gitleaks | 33287751613 | success |
| Trivy | 33287751625 | success |

Local runs were not substituted for cloud status at any point.

## 15. Local regression on schai

| Suite | Result |
| --- | --- |
| Generation-11 installer | PASS (122) |
| Generation-12 installer | PASS (77) |
| Generation-12 packaging | PASS (53) |
| Fabric install closure | PASS (17) |
| G11-X operation authority | PASS (55) |
| G11-Y current eligibility | PASS (49) |
| Execution admin | PASS (34) |
| Launch CLI | PASS (26) |
| Transition action | PASS (31) |
| Trust runtime | PASS (518) |

Every host-only suite still runs in full here — the point of keying the skip on
preconditions rather than a flag.

| Mode | Steps | Result |
| --- | --- | --- |
| Quick | 78/78 | `Validation passed (quick mode) … 78/78 steps.` exit 0 |
| Full | 101/101 | `Validation passed (full mode) … 101/101 steps.` exit 0 |

Totals unchanged from G11-Z4, as expected: this checkpoint added no suite to the
validator, only preconditions inside existing ones. `pre-commit run --all-files`
passes all five hooks; ShellCheck 0.9.0 passes over the widened file list.

## 16. Production no-mutation

| Surface | Value |
| --- | --- |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Fabric store | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Trust store | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` |
| Evidence + Artifacts | `1f58bad398bf141e3956e28d6210e7a333461e89d10051e197154e8d514f9c07` |
| Privileged helpers | unchanged |
| `/etc/sudoers.d/` | `README` only |

Identical before and after. `tools/capability/package_resolution.py` is back at
`0c5c9487…` after the digest-invalidation test, which was performed and reverted
in the working tree and never committed.

## 17. Actions not performed

No stage, no invoke, no CINV, no adapter, no sudoers, no Fabric or Trust
mutation, no CADV/CINST renewal, no CSEL, no route, no runtime install or
generation change. No production pin weakened, no `$PWD` inference, no
permissive default, no symlink of a runner workspace into
`/opt/schott-platform`. No repo-wide `--exclude-rule`, no `.semgrepignore` of the
runtime file, no inline suppression in digest-governed source. No failing
assertion deleted. None of the three carried-forward hardening items touched.

## 18. First-invoke readiness

Every condition in the gate is met:

- local quick 78/78 and full 101/101, exit 0;
- GitHub portable CI completely traversed — 98/98, nothing unrun;
- no hidden portable tail: the dark 63 steps have been observed, and the
  simulator that found them now reports only its own artefacts;
- all host-only skips explicit, enumerated, reason-bearing, and asserted in both
  directions;
- ShellCheck green at current HEAD;
- Semgrep green at current HEAD with zero unreviewed findings;
- the one approved exception is exact, narrow and fail-closed on ten mutations;
- no unresolved security defect affects the execution path;
- Generation 12 unchanged.

`FIRST_INVOKE_PREFLIGHT_READY = YES`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

Two things a reviewer may want to take up separately, neither blocking:

1. **Semgrep ruleset pinning** (§13) — reproducibility versus currency.
2. **The coordinator-identity coincidence** (§7, #3) — three suites depend on the
   operator account being uid 1000, now declared rather than assumed.

Carried forward unchanged:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`
