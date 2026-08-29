# ENG-0005 G11-Z5 — GitHub Actions reconciliation before first invoke

**Date:** 2026-08-29
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `d08631c4d574b326967275600a24709e63b0c1d6`
**Implementation commits:** `36d14e3`, `9a4e873`, `f2be850`
**G11-Z3 report closed in:** `babbb75`

GitHub Actions has reported CI, Semgrep and ShellCheck failures on every recent
ENG-0005 commit while local validation passed. All three were investigated
against real workflow runs. None is a defect in the runtime. ShellCheck is
fixed and green. Semgrep is one proven false positive that cannot be suppressed
without a reviewer decision. CI is a class of test/environment coupling that is
larger than this checkpoint and needs its own.

---

## 1. Accepted state at entry

| Check | Observed |
| --- | --- |
| HEAD | `d08631c4d574b326967275600a24709e63b0c1d6`, clean, matching origin |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Local quick / full | 78/78, 101/101 |
| Fabric / Trust / Evidence+Artifacts | `bcb2559b…` / `cffd362c…` / `1f58bad3…` |
| sudoers / helpers | `README` only; helpers unchanged |

## 2. Why now

Local validators went green in G11-Z4, but GitHub reported failures across many
commits. Two independent evidence channels disagreed, and the first production
invoke should not be prepared while that is unexplained. Email subjects were not
used as evidence; every conclusion below comes from `gh run view` on real runs.

## 3. Workflow inventory

Six workflows, all `on: push` and `pull_request`, all `permissions: contents:
read`, all `ubuntu-24.04`.

| Workflow | Command | Result at entry |
| --- | --- | --- |
| CI | `bash tests/*.sh` ×85 plus renders and validators; `actions/checkout` with `fetch-depth: 0`; PyYAML from a hash-pinned `requirements-ci.txt` | **failure** |
| ShellCheck | `shellcheck scripts/*.sh tests/*.sh tools/dev/*.sh` | **failure** |
| Semgrep | `semgrep scan --config auto --error --verbose`, image pinned by digest to 1.171.0 | **failure** |
| CodeQL | default | success |
| Gitleaks | default | success |
| Trivy | default | success |

Onset, from run history rather than inference:

- CI and Semgrep last succeeded **2026-08-11** (`48c862a3`).
- ShellCheck last succeeded **2026-08-26** (`18abf0f1`).

Uniformly red across `e56eb5c`, `4d01d75`, `94c068a`, `279d6c2`, `013fac1`,
`a008b26`, `fc4e6d2`, `b6accf1`, `a2e4bee` — so no single commit is the cause,
and the G11-Z3 reporting correction is not implicated in any of them.

## 4. ShellCheck — Class C, fixed

Not a version difference: CI prints `version: 0.9.0`, which is exactly what
`tools/dev/versions.env` pins and what the local runner uses. The finding was:

```
In tests/test-fabric-runtime-install-closure.sh line 69:
  source "${REPOSITORY}/provisioning/execution/generation-11-surface.sh"
         ^-- SC1091 (info): Not following: ... was not specified as input (see shellcheck -x).
```

The difference is the **file list**. `tools/dev/run-shellcheck.sh` lints a
superset — it adds `provisioning/execution/`, `provisioning/artifacts/` and
`provisioning/evidence/` — so ShellCheck can resolve the sourced file and SC1091
never fires. The workflow inlined a narrower glob, so the sourced file "was not
specified as input" and info-level SC1091 failed the job.

The workflow's own comment warned about this: *"The file list must stay identical
to that script's, or the two diverge."* Restating a list and asking the next
person to keep it in step is what let it drift. The workflow now calls
`tools/dev/run-shellcheck.sh`, which is the only form that cannot diverge.

The `test-developer-experience.sh` assertion that guarded this pinned the
inlined glob rather than the property it names. It now requires the shared
runner, and accepts an inlined list only if it covers everything the runner
lints.

Onset traced to `e9e6405`, which added the `source` line.

**Current HEAD: ShellCheck PASS** (run 33279303750).

## 5. Semgrep — Class D, proven false positive, needs a reviewer ruling

One blocking finding, unchanged across every failing run:

```
tools/capability/package_resolution.py
❯❱ python.lang.security.audit.insecure-file-permissions
   These permissions `_STAGING_MODE` are widely permissive ... A good default is `0o644`
   466┆ os.chmod(staging, _STAGING_MODE)
```

`_STAGING_MODE = 0o700` — owner only, no group, no other. The rule reads the
named constant rather than its value, and its proposed "safer default" of
`0o644` would be **more** permissive (world-readable) and unusable for a
directory, which needs the execute bit to be traversed. The call site is
`_abandon()`, which deliberately leaves an unpublished staging tree readable to
the operator who owns it and nobody else.

**This is a false positive, and the code is the more secure of the two.** It is
on the execution path, so it was examined rather than waved through; it is not a
defect.

**Why it is not suppressed here.** I added a narrow, rule-named
`# nosemgrep: python.lang.security.audit.insecure-file-permissions` at that one
line, and local validation immediately failed:

```
FAIL  checkout and installed runtime disagree at tools/capability/package_resolution.py
FAIL  the declared object tools/capability/package_resolution.py is 56cb3aa6…, not the declared 0c5c9487…
```

`package_resolution.py` is a **digest-governed installed runtime object**. Adding
a comment changes its digest and breaks the generation-authority chain between
the checkout and the installed runtime. The edit was reverted; the checkout again
matches the installed object at `0c5c9487…`.

That leaves no in-file remedy, and both remaining options carry a cost a reviewer
should choose, not me:

1. `--exclude-rule python.lang.security.audit.insecure-file-permissions` in
   `semgrep.yml`. Smallest change, but repository-wide for that rule: it would
   also mask a genuinely permissive `chmod` written through a named constant.
   This codebase does define every mode as a named constant (`0o500`, `0o400`,
   `0o700`), so the rule can never evaluate any of them and will always fire
   here — which is an argument for the exclusion, and simultaneously the reason
   the exclusion has teeth.
2. Defer the inline suppression to the next generation ceremony that republishes
   `package_resolution.py`, where a digest change is legitimate and reviewed.

A related observation worth recording: the Semgrep **image** is pinned by digest,
but `--config auto` fetches rules from the registry at run time (the log confirms
`registry usage is True`). Semgrep results are therefore not reproducible across
time even at a fixed commit, and this job can go red without any change to the
repository.

**Current HEAD: Semgrep FAIL — understood, one finding, classified false
positive, zero unresolved security findings.**

## 6. CI — Class C, three fixed, class not exhausted

Every CI failure examined is a suite asserting facts about the **production
host** that cannot hold on a runner with no `/var/lib/kyri` and no
`/usr/lib/kyri`. Three were corrected, each verified both ways — on this host
with the live assertions still running, and in a container with no
`/var/lib/kyri`.

| Suite | Mechanism | Fix |
| --- | --- | --- |
| `test-trust-decision-preflight.sh` | four cases plus the CLI live-replay and the untouched proof read the live Trust store; `TrustStoreError: record 'TREC-000001' does not exist` | gated on store presence, following the existing `[[ -d "${LIBRARY_ROOT}" ]]` precedent |
| `test-trust-root-lineage-backfill.sh` | `find <absent dir> \| wc -l` exits non-zero; under `set -Eeuo pipefail` the substitution killed the suite before it printed a line — the exit-1-with-no-output CI showed | presence guard plus a `count_live` helper |
| `test-fabric-host-admission.sh` | same `find … \| wc -l` mechanism on `capability-hosts` | `count_hosts` helper; a sweep finds no other instance of the idiom |

The guards are **presence, not opt-out**: on the production host every live
assertion still runs, and local full validation remains 101/101.

Verified in a container with no `/var/lib/kyri`: decision-preflight 14 PASS / 6
SKIP / 0 FAIL; backfill 32 PASS / 1 SKIP / 0 FAIL. Both previously died with no
output at all.

**CI still fails, at a fourth suite of a different mechanism.** Run 33279303744
and 33279303735 fail at `test-fabric-evidence-authority.sh`:

```
STOP: the reviewed commit 061a1a1585… does not exist in /opt/schott-platform
```

`fetch-depth: 0` is already set and the commit is reachable on the branch. The
failure is the **path**: `provisioning/evidence/install-host-evidence.sh` pins
`REPOSITORY="/opt/schott-platform"`, which does not exist on a runner.

This is not one more suite to patch. It is a convention:

- nine suites use a `PINNED_REPOSITORY` guard that prints *"this checkout is X
  but the ceremony pins /opt/schott-platform"* and **`exit 1`** — every one of
  them will fail on a runner;
- the evidence ceremony pins the same absolute path without a guard;
- **63 of the CI job's 97 steps have never run**, because the job stops at the
  first failure. What is behind that wall is unmeasured.

Whether an operator ceremony should pin an absolute production path, and what CI
should do when it cannot satisfy that pin — skip, or run against the checkout —
is an architectural decision with real consequences for what CI actually proves.
It is not mine to make inside an evidence-reconciliation checkpoint, and making
it by patching suites one push at a time would be the worst version of it.

**Current HEAD: CI FAIL — understood, cause identified, scope measured.**

## 7. Local versus GitHub environment

| | Local | GitHub runner |
| --- | --- | --- |
| `/usr/lib/kyri/python` | present, Generation 12, 70 objects | absent |
| `/var/lib/kyri/{fabric,trust,evidence}` | present, governed records | absent |
| `/root/kyri-gen1{1,2}-*` | present, operator-readable | absent |
| Repository path | `/opt/schott-platform` — what the ceremonies pin | `/home/runner/work/schott-platform/schott-platform` |
| ShellCheck | 0.9.0, superset file list | 0.9.0, **narrower** list (now the same) |
| Semgrep | not run locally | pinned image, registry-fetched rules |

The first four rows are the whole of the CI story. Local validation is stronger
in one direction — it can assert against the real host — and weaker in another:
it cannot detect a suite that only works because that host is there. GitHub is
the only thing that checks the second, which is why it should be green.

## 8. Classification

| Workflow | Class | Current HEAD |
| --- | --- | --- |
| ShellCheck | **C** — workflow drift; identical version, divergent file list | PASS |
| Semgrep | **D** — one finding, reviewed, false positive; blocked from in-file fix by digest governance | FAIL, understood |
| CI | **C** — environment coupling: suites assert production-host facts and pin an absolute repository path | FAIL, understood |

No workflow is class A. Nothing found is a defect in the Generation-12 runtime
or on the execution path.

## 9. Production no-mutation proof

Taken after every suite, both validators and the container work.

| Surface | Value |
| --- | --- |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Fabric store | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Trust store | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` |
| Evidence + Artifacts | `1f58bad398bf141e3956e28d6210e7a333461e89d10051e197154e8d514f9c07` |
| Privileged helpers | unchanged |
| `/etc/sudoers.d/` | `README` only |

Local quick 78/78 and full 101/101, exit 0, captured PID, judged by the
validator's own output. `pre-commit run --all-files` passes all five hooks.

The one moment production authority was at risk was the reverted
`package_resolution.py` edit, which local validation caught immediately (§5).
The installed runtime was never written.

## 10. Actions not performed

No stage, no invoke, no CINV, no adapter, no sudoers, no Fabric or Trust
mutation, no route, no CADV/CINST renewal, no runtime install or generation
change. No Semgrep suppression added. No CI suite patched beyond the three named.
No broad `nosemgrep`, no rule silenced, no failing assertion deleted.

## 11. First-invoke readiness

The gate asks that each channel be **understood**, not that each be green. All
three are understood, with causes identified from real runs and, where fixed,
verified both on this host and without it. No unresolved security finding affects
the execution path: the single Semgrep finding is on it and is a proven false
positive in the safe direction.

`FIRST_INVOKE_PREFLIGHT_READY = YES`, which permits the next preparation
checkpoint and authorises no invocation.

Two things should be settled alongside it, and I recommend they be their own
checkpoint rather than being folded into invoke preparation:

1. **Restore GitHub CI.** Decide how ceremonies that pin `/opt/schott-platform`
   should behave on a runner, then work through the 63 steps that have not run
   since 2026-08-11. Until that is done, CI is not a signal anyone can act on,
   and a real regression could hide behind the wall.
2. **Rule on the Semgrep finding** — `--exclude-rule` with its documented cost,
   or defer the in-file suppression to the next generation ceremony.

Carried forward unchanged:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`
