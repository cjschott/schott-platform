# ENG-0005 G11-AU — the transaction that moves a whole generation

**Date:** 2026-09-01
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `7709cf0443ab11f2b84c94eefbbb60f1eb95c98c`
**Implementation:** `3339438`, `6f5206b`, `7da7539`

The Generation-13 installer exists and is proven. A host that fails part way
through it is a whole Generation 12 or a whole Generation 13, and nothing in
between — including the three splits that would let a runtime execute real
workloads under semantics nobody reviewed.

**Nothing was installed.** Production is still Generation 12, the helpers are
still stale, both grants are closed, and neither identity authority exists.

Quick **97/97**, full **122/122**.

---

## 1. Starting authority, and what re-deriving it found

Branch, tree, divergence and ancestry all checked out. The host is Generation
12: 70 library objects, no Generation-13 target present, no transaction residue.

**The brief's aggregate digest could not be reproduced, and chasing it was the
wrong move.** `9cbfd043…33830` appears in three reports and no repository
artefact defines how it was computed; six plausible formulas over the installed
tree produce six other values. So the baseline was proven the way the
transaction model actually proves it — **per object** — and that turned up
something the aggregate never would have.

### Two objects the declaration was wrong about

Running the G5 preflight's `--verify-source` against the **live host** (rather
than against the fixtures every case in its suite builds) failed:

| Object | Installed | Declared | Reviewed bytes from |
| --- | --- | --- | --- |
| `tools/capability/records.py` | `a674…a38e` | baseline `563e4a…` only | `9300250` (2026-08-28) |
| `tools/capability/execution/launch.py` | `ca606a94…` | `CREATE\|ABSENT` | `bc05f911` (2026-08-16) |

`records.py` carried the Generation-11 baseline only; Generation 12 installed a
newer one and the row was never widened, so from that moment the host held bytes
the invariant called undeclared drift. `launch.py` was declared CREATE, but
Generation 8 installed it and it has been there ever since; G11-AT then moved
the checkout, and a CREATE row demands the installed object be absent or already
at the new bytes.

Both installed objects were traced to real commits by hashing every historical
revision of each path, so **the host was never in an unexplained state and
nothing needed repairing on it.** The declaration was wrong, not the machine.

**Why it stayed wrong is the part worth keeping.** Every case in the G5 suite
builds a generation-6 fixture, so for two generations the declaration was only
checked against a tree that predates most of it. The live host is exactly the
shape it governs and was the one shape nothing ran it against. It now runs
against a fixture mirroring the live library root — where both of these would
have been caught the day they appeared.

Fixed in `3339438`, before anything else, because a Generation-13 installer
whose whole job is to pin the Generation-12 baseline cannot be built on a
declaration that is wrong about it.

## 2. The closure

Computed from the production entry roots, not asserted. **73 objects.**

| Root | Why it is one |
| --- | --- |
| `tools.capability.cli` | the operator interface: invoke, authorise-launch, execute, recover, inspect, validate |
| `tools.capability.execution.worker` | the far side of `execve` |
| `kyri_exec_worker` | the released worker entrypoint — and how the Podman backend enters the graph |
| `kyri_exec_transition`, `…_action`, `kyri_exec_verify`, `kyri_exec_quota` | executed by root through the flattened library copies |

**Nothing is whitelisted.** G11-AT found two modules that entered only by
accident of how they were imported — `recovery.py` had no released entry root
and `kyri_exec_launcher` was reached through `importlib`, which the closure
cannot follow — and both were fixed at the source. The packaging suite asserts
they are reachable *because the graph reaches them*, not because they are
listed.

Identical at the reviewed authority and at HEAD, which is what makes the pin
meaningful.

## 3. The matrix

Classified from live installed bytes, object by object.

| | |
| --- | --- |
| `GEN13_OBJECTS` | **73** |
| `GEN13_REPLACE` | **13** |
| `GEN13_CREATE` | **8** |
| `GEN13_CARRYOVER` | **47** |
| helper-ceremony objects inside the closure | 4 |
| entry-point objects outside the library root | 1 |
| library object count | 70 → **78** |

**CREATE** — `supervision.py`, `recovery.py`, `helpers.py`, `identity.py`,
`mount_evidence.py`, `rehearsal.py`, `kyri_exec_podman.py`,
`kyri_exec_launcher.py`.

**REPLACE** — `protocol.py`, `adapter.py`, `lifecycle.py`, `worker.py`,
`profile.py`, `launch.py`, `coordinator.py`, `evidence.py`, `records.py`,
`inspection.py`, `store.py`, `package_resolution.py`, `cli.py`.

Six installed objects sit outside the closure — `admin.py`, `cleanup.py`,
`quarantine.py`, `quota.py`, `verification.py`, `yaml_strict.py`. They are
carried over untouched and accounted for by the Generation-12 evidence. The
closure is a lower bound on what must be importable, not an upper bound on what
may be installed, and removing them was never this transaction's business.

### A refinement to earlier accounting

G11-AS and G11-AT listed `kyri_exec_podman.py` under the *helper* delta. Building
the installer forced the question properly, and the discriminator is whether
**root** imports it: root imports `kyri_exec_transition` and its action module
before the drop, and nothing else. `kyri_exec_podman` is imported by the worker
*after* the drop; `kyri_exec_launcher` by the unprivileged coordinator. Both are
Generation surface, and §12 shows what follows from that.

## 4. Coherence groups

Declared as a column on every row, so a split names a capability rather than a
list of pathnames.

| Group | What it is | Rows |
| --- | --- | --- |
| **A** | execution and supervision | 10 |
| **B** | result and lifecycle | 7 |
| **C** | identity, recovery and readiness | 4 |

`require_group_coherence` asserts every group is wholly at one generation, and
the pairings that make it matter are pinned in the packaging suite: the worker
with its backend, the supervisor with its launcher, the result contract with its
writer, recovery with readiness.

The transaction already guarantees this — any pre-COMMITTED failure returns every
row to baseline — so the group check is the statement of what would be wrong if
it ever did not, and the failure-injection matrix is where it is exercised.

## 5. Installer architecture

`provisioning/execution/install-generation-13.sh`, five modes:
`--verify-source`, `--verify`, `--install`, `--verify-installed`, `--recover`.

The transaction model is Generation 12's, carried forward because it is accepted
and correct: PREPARE everything before publishing anything, publish by
`rename(2)`, journal before every irreversible step, decide classification from
bytes and never from the journal.

**What was not carried forward.** Generation 12 created a package directory and
carried the machinery for it — creation, rollback removal, `package_dir_created`
in the journal, a foreign-object gate. Every Generation-13 target lands in a
directory that already exists, so none of it is here. Copying it would have
meant maintaining a branch nothing takes, which is the same mistake that gave
Generation 12 a `require_same_filesystem` that could not pass its own matrix.

**One bug of my own, found by the fixture.** `--verify-source` first consulted
the library root to decide what the predecessor provides, which made a sound
package report as broken against an empty root. It now asks the reviewed
Generation-12 **authority** whether it carries each carried-over object — which
is the question that was meant, is decidable from source alone, and is what
makes the mode's own claim ("no installed path was read for state") true. The
suite runs it against an empty fixture precisely to keep that honest.

## 6. Journal namespace

`/root/kyri-gen13-transaction`, `kyri-gen13-library-digests.txt`,
`kyri-gen13-helper-digests.txt`, staging suffixes `.kyri-gen13.new` /
`.kyri-gen13.gen12`, fault variable `KYRI_GEN13_FAIL_AT`.

Generation 12's retained journal is predecessor evidence: never read as this
transaction's state, never written, never removed. The installer suite asserts
`/root/kyri-gen12-transaction` is not so much as created, and that the ceremony
carries no reference to the predecessor's fault variable — the G11-Z failure,
pinned rather than remembered.

## 7. PREPARE

All twenty-one objects staged and verified before a single publication. Each
CREATE reserves a genuinely free pathname (a symlink there is the substitution
this refuses to publish through); each REPLACE proves the target is the declared
baseline, retains the predecessor beside it, and proves the retained copy
matches what it was taken from.

An interrupted PREPARE unwinds: staged material removed, retained predecessors
removed only where the target is still that predecessor, journal removed rather
than moved to a terminal state — because nothing was published under it and a
host with no transaction should say so.

Proven at `stage`, `staged` and `prepared`: whole Generation 12, no residue.

## 8. COMMIT

One transaction, twenty-one pathnames. `rename(2)` is atomic for one pathname;
the journal is what carries the other twenty, and every intermediate state fails
closed. Each publication is followed by a digest check, a mode check and — off
fixture — an ownership check, any of which rolls the whole thing back.

**The commit point is reached only after every target has published and
verified**, not on a count and not on the journal's own say-so. Everything after
that line is bookkeeping: failures at `postcommit`, `evidence` and `cleanup` all
leave Generation 13 standing, and the suite proves each.

## 9. Rollback

Both directions, because this matrix has both dispositions: a CREATE is undone
by removal, a REPLACE by restoring the retained predecessor. Both are fenced —
a file that is not exactly what this transaction put there is reported and left
alone, never removed.

Proven at `committing`, `publish`, `verify`, `precommit`, and at four chosen
commit positions.

## 10. Recovery

Direction decided from provable material:

| Observed | Direction |
| --- | --- |
| unknown bytes anywhere | **stop** for operator disposition |
| every target already Generation 13 | settle as COMMITTED |
| every target still Generation 12 | settle as ROLLED_BACK |
| mixed, every remaining prepared object verifies | complete **forward** |
| mixed otherwise | roll **back** |

A mixed host is by definition a split generation, so the direction is decided by
what can be proved rather than by which side has more rows.

`--recover` on a committed transaction settles without rolling anything back;
an accepted Generation 13 is never downgraded. A COMMITTED journal whose targets
disagree halts for disposition — the journal does not win.

## 11. Unknown bytes

Refused, and left byte-identical. Proven for both classes: a REPLACE whose
predecessor is not the declared baseline, and a CREATE whose pathname is
occupied. Both the install **and** the recovery refuse, and both leave the
operator's bytes exactly as found — a recovery that overwrote them would be
worse than the install that refused.

## 12. Which ceremony comes first, demonstrated

The brief asked me to prove the order rather than assume it. The answer is
**Generation 13 first, the helper ceremony second**, and the proof is a
demonstration rather than an argument:

| Fixture | `import kyri_exec_podman, kyri_exec_launcher` |
| --- | --- |
| Generation 12 | **unresolvable** |
| Generation 13 | **resolvable** |

The helper ceremony installs a worker entrypoint that imports the Podman
backend, and the backend is a Generation-13 object. Installing the helpers first
would produce a worker that cannot resolve what it imports. The packaging suite
also asserts from the matrix that both modules are this generation's, so if
either ever moved to the helper ceremony the ordering argument would have to be
re-made rather than silently inherited.

**Installable is not execution-ready, and the installer says both.** Generation
13 installs onto a host with stale helpers and no identity authorities: the
runtime imports fine, because every one of those is read at execution time and
refused there. What such a host cannot do is execute — `helpers.compatibility()`
reports the supervision path incompatible and the supervised preflight reports
it not ready. So the installer does not demand deployment files it does not
need, and reports the gap instead of pretending it is a blocker.

## 13. Fixture ceremony

Built from the live installed library, which is the shape this ceremony governs.

```
--verify-source   → 21 objects would change (13 REPLACE, 8 CREATE)
--verify          → at Generation 12, ready; NOT execution-ready
--install         → PREPARE 21, COMMIT 21, evidence written, artefacts removed
--verify-installed→ all checks passed
--install (again) → already installed: nothing to do
```

78 objects afterwards. Generation-13 evidence written, Generation-12 evidence
preserved, journal COMMITTED, no residue. A second `--install` mutates nothing
and rewrites neither journal nor evidence.

## 14. Installed import proof

Every production entry root imports from the fixture library root with the
repository removed from `sys.path` and the working directory moved off it, and
each module's `__file__` is asserted to be under the package. A packaging test
that could fall back to the checkout would pass on a package missing a module.

`cli`, `worker`, `adapter`, `lifecycle`, `protocol`, `supervision`, `recovery`,
`helpers`, `identity`, `kyri_exec_podman`, `kyri_exec_launcher` — all from the
installed tree.

## 15. Supervision proof from installed bytes

Run through the packaged runtime, not the checkout:

- a full protocol exchange concludes `completed`, `succeeded=True`, the released
  `sha256:` digest, exactly one message sent by the coordinator, disposal proven,
  worker reaped;
- a worker announcing a start it was never granted is refused, and
  reconciliation still runs;
- end of stream produces **no outcome and no classification**, and reconciliation
  still runs;
- the execution-safety gate reports `ready` and `not-ready`, names the blocking
  invocation, marks it interrupted, and writes no result.

## 16. G11-X and G11-Y from installed bytes

The per-invocation operation and scope refusals are read as **declared
constants** rather than as text, and the current-eligibility revalidation is
asserted from the installed module's **call graph** — `evaluate_eligibility` is
called and both reader classes exist. The Trust decision surfaces and the Fabric
write path are not importable from the installed package.

## 17. Privileged-surface exclusion

`PRIVILEGED_SURFACE_EXCLUDED = YES`, proven three ways.

- **Structurally**: no matrix row may name a helper library object, a `libexec`
  entrypoint, either grant, or either identity authority — checked on every run
  before anything is staged.
- **By fingerprint**: the whole privileged set is hashed before and after the
  install and required to be identical.
- **By manifest**: the fixture's `/usr/libexec`, `/etc/sudoers.d` and `/etc/kyri`
  are byte-identical across a full install, and the suite asserts the runtime
  installer created no identity authority and no grant.

## 18. Deployment candidates

Revalidated, none installed.

| Candidate | Bytes | SHA-256 | Destination |
| --- | --- | --- | --- |
| coordinator identity | 76 | `3dec888c…2811` | `/etc/kyri/coordinator-identity.json` `root:root` `0444` |
| execution identity | 99 | `891beeeb…e373` | `/etc/kyri/execution-identity.json` `root:root` `0444` |

Both re-derived from live facts and rehearsed through the accepted parsers —
byte-identical to their accepted values, so nothing was regenerated casually.
Both destinations are absent.

## 19. Helper candidates

Cumulative delta against the live installed helper set: **10 objects change.**

| Object | Installed | Proposed | State |
| --- | --- | --- | --- |
| `kyri_exec_transition.py` | `6488044bc824` | `de264c6490e0` | REPLACE |
| `kyri_exec_transition_action.py` | `bd32af5de4f3` | `7703231318f7` | REPLACE |
| `kyri_exec_verify.py` | `3d70707d19c3` | `f49c29571a4e` | REPLACE |
| `kyri_exec_quota.py` | `4886d5b323c9` | `4886d5b323c9` | unchanged |
| `kyri_exec_reconcile.py` | absent | `29175d5a7175` | CREATE |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf6342` | `0d9c8d8c9181` | REPLACE |
| `/usr/libexec/kyri-exec-verify` | `fad96924adbb` | `1c87788c6559` | REPLACE |
| `/usr/libexec/kyri-exec-quota` | `4886d5b323c9` | `4886d5b323c9` | unchanged |
| `/usr/libexec/kyri-exec-worker.py` | `64260190330b` | `6d06695f4335` | REPLACE |
| `/usr/libexec/kyri-exec-verify-worker.py` | `5a614ff73c0d` | `c747c6d0c306` | REPLACE |
| `/usr/libexec/kyri-exec-reconcile` | absent | `2878fff04bb2` | CREATE |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | absent | `b0e3c047f689` | CREATE |

`INSTALLED_HELPER_STILL_STALE = YES`.

## 20. Sudoers candidates

Two rules, independently revocable, against the final entrypoint digests.

```
Cmnd_Alias KYRI_EXEC_TRANSITION = sha256:0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1 \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$
Cmnd_Alias KYRI_EXEC_RECONCILE  = sha256:2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77 \
    /usr/libexec/kyri-exec-reconcile  ^CINV-[0-9]{6}$
```

`visudo -c` under **sudo 1.9.15p5**: both parse. No wildcard, no container
argument, no shell, one `CINV` regex each. The principal is derived by
`sudoers_principal()` from the coordinator authority candidate.

**Neither installed.** `SUDOERS_CLOSED = YES`.

## 21. Compatibility expectations

The generation records what it expects beside it, in the evidence file where a
generation already states what it installed:

```
expects_coordinator_identity /etc/kyri/coordinator-identity.json
expects_execution_identity   /etc/kyri/execution-identity.json
expects_helper /usr/libexec/kyri-exec-transition            0d9c8d8c…
expects_helper /usr/libexec/kyri-exec-worker.py             6d06695f…
expects_helper /usr/libexec/kyri-exec-reconcile             2878fff0…
expects_helper /usr/libexec/kyri-exec-reconcile-worker.py   b0e3c047…
```

**No new authority plane.** The lines are read from the runtime's *own*
declaration in `helpers.py` rather than restated, so there is one place that
decides and one that records; the packaging suite asserts the two agree. Nothing
reads this at execution time — `helpers.compatibility()` and the supervised
preflight decide from installed bytes — so it is the auditable record of the
expectation, written at the moment it became true.

## 22. Current production state

Read-only, after every suite had run.

| Surface | Observed |
| --- | --- |
| Host generation | **12** — 70 library objects |
| Per-object aggregate (path + bytes) | `846ff61b…7e8e` |
| Generation-13 CREATE targets | **none present** |
| Generation-13 transaction residue | **none** |
| `/root/kyri-gen13-transaction` | unreadable by the coordinator — which is the correct permission |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf6342` — stale |
| `/usr/libexec/kyri-exec-reconcile` | **absent** |
| sudoers drop-ins (excluding the distribution README) | **0** |
| coordinator identity authority | **absent** |
| execution identity authority | **absent** |
| Newest CADV validity | expired `2026-08-30T16:19:19-05:00` |

The aggregate above is stated with its formula — a per-object hash over relative
path and bytes — because §1 is why an aggregate with no stated formula is worth
less than the per-object proof beside it.

## 23. Deployment order

Derived from the code. Steps 1–4 are the ones §12 settled by demonstration.

1. **Generation 13** — `--verify-source`, `--verify`, `--install`,
   `--verify-installed`. First, because the helper set imports objects this
   generation installs.
2. **Coordinator identity authority** — 76 bytes, `3dec888c…`, `root:root 0444`.
3. **Execution identity authority** — 99 bytes, `891beeeb…`, `root:root 0444`.
   Both before the helpers, because the launch helper reads them before anything
   else and has no constant to fall back to.
4. **The coherent helper set** — all ten changing objects, together. A partial
   install is the G11-AI defect.
5. **Verify helper coherence** — `helpers.compatibility()` reports `compatible`,
   or nothing after this point is safe.
6. **Supervised invoke preflight, read-only** — expect everything except the two
   grants, which this surface may not observe.
7. **Renew CADV** — the chain expired on 2026-08-30.
8. **Admit a bounded CINST**, then **CROUTE successor**, then **CSEL**.
9. **Install the two narrow sudoers grants** — last, because until here there
   was nothing safe for them to authorise.
10. `capability invoke --preflight`, then `invoke`, then `authorise-launch`.
11. **One controlled `capability execute`** — the first production run of the
    released binary.
12. **Verify CINV, CRES and the result digest.**
13. `capability recover` — expect `ready`, zero unresolved.
14. **Decide whether the grants stay installed.**

Generation 13 moved from step 5 to step 1 relative to G11-AT's ordering, and
that change is the checkpoint's most consequential finding after §1.

## 24. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 97/97 |
| `run-validation.sh` (full) | **PASS**, 122/122 |
| Generation-13 installer (new) | **PASS**, 45 cases |
| Generation-13 packaging (new) | **PASS**, 21 cases |
| G5 preflight, live-shaped case (new) | **PASS** |
| supervision, reconcile entrypoint, identity authority | **PASS** |
| capability runtime, launch CLI, invoke E2E, supervised E2E | **PASS** |
| ShellCheck, Semgrep, pre-commit | clean |
| GitHub workflows | see handoff |

Three defects of my own, recorded because two are recurrences of the same habit:

- `--verify-source` consulted the host to answer a source-only question, which
  made a sound package look broken. Found by the empty-fixture case that exists
  to catch exactly that.
- A test queue whose logic read as if it withheld frames and did not, and a
  G11-X check with a substring fallback a comment would have satisfied. Both
  rewritten before being trusted — assert on structure, not on text.
- A `local a="$1" b="${WORK}/${a}"` that referenced `a` before it was set. Caught
  by `set -u`, which is why it is there.

## 25. Production non-mutation

`install-generation-13.sh --install` was **never run against production**. Every
install in this checkpoint targeted a throwaway root under `/tmp` built from a
copy of the installed library.

Not installed: Generation 13, the coordinator identity, the execution identity,
the launch helper, the reconcile helper, either sudoers grant. No Fabric
renewal, no production invoke, no production CINV or CRES, no container.

The installed production runtime was hashed before and after the installer suite
and is byte-identical.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 26. Next

**`install-generation-13.sh --verify` on the production host**, as the operator,
on a clean tree — the first step of §23 and the last read-only one before an
install. Everything after it is the deployment sequence, in that order.
