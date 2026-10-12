# ENG-0005 G11-BB-H — Phase 5B, generation succession

**Status: Phase 5B complete. Validation and CI fully green.** Production
untouched. `CINV-000001` byte-identical, `CINV-000002` unspent. Nothing was
built for Generation 15 or the helper ceremony, as ruled.

Branch `arch/eng-0005-execution-transition`, HEAD `0f47281`.

---

## 1. Root cause

The declaration models a transition as

```
source_path | operation | installed_baselines | declared_target
```

and classifies a difference between the installed object and the checkout by
asking whether **installed** is one of the baselines and **checkout** is the
target. The installed side was already a comma-separated list. **The checkout
side was a single value, deliberately** — the shipped comment said so:

> *"Only the installed side widens. The checkout must still be the declared
> bytes, so nothing unreviewed becomes admissible by naming another baseline."*

That reasoning is right about a wildcard and wrong about a list, and the cost
was that **a reviewed correction could not be expressed at all**. A correction
that is reviewed and not yet installed *is* a checkout ahead of the declared
target. A single-valued row has no verdict for that but drift, so the artefact
reported reviewed source as corruption — and the only way to quiet it would have
been to overwrite the historical digest it had already accepted, which is the
one thing a declaration must never do.

`G5_PREFLIGHT_ROOT_CAUSE = the declared-target side of a generation row admitted
exactly one digest, so a reviewed successor beyond it had no classification
other than unknown drift.`

## 2. Every failure, classified before editing

Reproduced at `5f0bf1b`: **5 suite-level failures**, 6 detail lines.

| object | installed | declared predecessors | repository source | known successor authority? | was | should be |
| --- | --- | --- | --- | --- | --- | --- |
| `tools/capability/cli.py` | `752951f7…` | `990bd8ca…, c10bf11e…, b45f5332…` | `7b4fac3e…` | yes — the G11-BB correction, reviewed in this branch | unknown-drift | **accepted-installed-predecessor** |
| `tools/capability/execution/recovery.py` | `a93819d1…` | `ABSENT` (CREATE) | `f44ada7f…` | yes — same correction | unknown-drift | **accepted-installed-predecessor**, on an *applied* CREATE |
| `tools/capability/execution/helpers.py` | `74b84015…` | `ABSENT, eff6c4fd…` | `6dd93606…` | yes — same correction | unknown-drift | **accepted-installed-predecessor** |

Three objects, three identical causes. The two remaining suite failures
(*"the declared change at cli.py is neither pending nor applied"*, *"checkout and
installed runtime disagree"*) are the same three objects reported through the
other two checks, not separate defects.

**`kyri_exec_launcher.py` is not in this table** and does not need to be: the
drift loop walks `find tools -type f -name '*.py'`, and that object lives at the
library root outside `tools/`.

## 3. The existing pattern, used rather than reinvented

The vocabulary already existed in this artefact — baseline / target /
pending / applied, with a widened baseline list — and the fix extends it
symmetrically instead of introducing a second one. Field 3 becomes a
comma-separated list of **declared successors**, exactly as field 2 already was
for baselines.

```
A  installed ∈ baselines,  checkout ∈ successors   -> accepted-installed-predecessor   PASS
B  installed ∈ successors                          -> known-successor-applied          PASS
C  neither                                          -> unknown-drift                    REFUSE
```

**Authority is explicit, not inferred.** A successor is admissible only because
it is written into the row and reviewed as part of this file. There is no
"anything newer", no "any commit after the baseline", no ancestor-of-HEAD test,
and nothing derived from `git diff`. A list is not a wildcard: every admissible
digest on either side is still spelled out.

**CREATE stays distinct**, as required. `ABSENT` remains its pending state and
the drift loop can never reach the classifier for it — that loop walks installed
objects. Arriving there means the object *is* installed, so the CREATE was
applied and a further change is REPLACE-shaped against the digest the CREATE put
there. The row is satisfied only when the host sits at a **strictly earlier**
declared hop than the checkout; a pair in the wrong order is a downgrade, not
development.

## 4. Historical evidence is intact

No digest was edited, replaced or removed. Each of the three rows **gained** its
previous target as an additional accepted baseline and its corrected bytes as an
additional successor:

```
cli.py       baselines += 752951f7…    successors: 752951f7…, 7b4fac3e…
recovery.py  baselines:  ABSENT        successors: a93819d1…, f44ada7f…
helpers.py   baselines += 74b84015…    successors: 74b84015…, 6dd93606…
```

Every digest that was accepted before is still accepted and still reads the same
way. Generation 5, 13 and 14 evidence, the production digest files and the
ceremony journals are untouched.

## 5. RED-first

`tests/test-capability-execution-generation-succession.sh` — 16 assertions. It
extracts `generation_declares` and `generation_row_coherent` **from the shipped
preflight by name**, so it proves the real bytes and a rename breaks the
extraction loudly rather than silently testing a copy.

Against the pre-fix implementation:

```
FAIL  A: accepted predecessor + declared successor source was refused
FAIL  A: the second declared baseline was refused
FAIL  A: widening broke the original transition
FAIL  9: an applied CREATE could not advance
FAIL  B: the applied newest successor was rejected
FAIL  B: an earlier declared hop was rejected
Generation succession validation FAILED: 6
```

**Six failures, every one a successor-awareness case.** Every refusal
assertion — unknown installed bytes, unreviewed checkout bytes, an undeclared
object, a successor named on another row, a backwards CREATE, retroactive
blessing of unrelated bytes — was **green before and after**, which is the
evidence that nothing was weakened.

Coverage against the required matrix: 1 ✓, 2 ✓, 3 ✓, 4 ✓, 5 — a row is matched
by path so a successor cannot attach to the wrong predecessor, covered by *"a
successor not named on THIS row is refused"*; 6 ✓ (digest mismatch either side);
7 ✓ (undeclared object); 8 — covered by the preflight's own CREATE/ABSENT
handling and its live-host case; 9 ✓; 10 ✓; 11 ✓ (§6); 12 ✓.

## 6. The second stale invariant

`test-capability-execution-launch-bridge.sh` carried the same assertion
`launch-cli` did: the live handoff root is empty. It is not, and will never be
again — `CINV-000001` is there.

A name-based check would be no better here: this suite's fixture identities
**include `CINV-000001`**, so it would be ambiguous in exactly the wrong
direction. So nothing is asserted about the contents. What the suite owes — that
it changed nothing — is already proven by the before/after production snapshot
around the whole run, covering mode, owner, size and both timestamps for every
production path. That is strictly stronger than the listing check it replaces,
and it was already running.

## 7. Two things the run caught that I had missed

**Three suites were never registered.** The developer-experience guard failed
with *"test suites exist that local validation never runs"*, naming the
handoff-traversal, authority-anchor and recovery-discovery suites — written,
committed and passing across three checkpoints, and invoked by nothing. A suite
no runner runs proves nothing. All four are now in `run-validation.sh` and
`ci.yml`, and the declared step totals moved with them (102→106 quick,
127→131 full) so the runner's own count check stays honest.

**Two files missed a commit.** `606cea3` described the successor fix but did not
contain it: a `stash`/`pop` cycle during an unrelated flakiness investigation
unstaged `g5-preflight.sh` and the bridge suite after they had been added.

That produced the worst shape a change can take — **local green against a working
tree that had the fix, CI red against a commit that did not**, and a test whose
failure output looked exactly like the pre-fix behaviour it was written to
catch, because that is precisely what CI was running. Corrected in `0f47281`
and verified by running the suite against a clean clone of the pushed commit
rather than the working tree.

**One flaky suite, not a regression.** `test-capability-invoke-execution-e2e.sh`
failed once at step 79 with three container rows collapsing to `adapter-error`,
then passed on re-run and in both full validations. It is timing-sensitive under
concurrent Podman load — two container suites had just run. Recorded, not
chased; it is not caused by any change here.

## 8. Validation

```
LOCAL_QUICK   PASS   106/106 steps
LOCAL_FULL    PASS   131/131 steps
GITHUB_CI     PASS   6/6 workflows at 0f47281
                     CI, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy
```

## 9. Production

```
CINV-000001   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CRES          0 records
fabric        7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
libexec       489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86   unchanged
/etc/kyri     root:root 0711        unchanged
handoff root  cschott:cschott 0711  unchanged
```

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 10. Next

Phases 7 and 8 are now unblocked by the validation gate. Both deltas should be
**re-derived** rather than taken from BB-G, per the ruling — the corrections
have moved since. Generation 15 first, then the three-object helper ceremony,
neither installed. Chain renewal after deployment and acceptance, not before.
