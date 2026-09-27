# G11-BC-AI — ADR-0018 ratified, and Generation 22 prepared to prove itself

**Date:** 2026-09-27
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `646b12799a0b5438d1d346f56a9a9a9f9e65299a`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — Generation 22 is prepared and not installed; the CADM-000004 correction ceremony is prepared and not executed. **Production was not mutated by this checkpoint.**

---

## 0. The one number that matters

The governed runtime store aggregate was measured before and after **every**
executable group in this checkpoint:

```
find /data/kyri/capability-runtime -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
35e33adc98a777964f56c626b58ff5d6945594946862ec7d6a233be98b276c4f
```

Unmoved throughout. Fabric `a87c2010…12e5` and Trust `53605e4e…b63f` likewise.
Fabric authority remains expired and was **not** renewed; no expired-authority
assertion was weakened.

## 1. ADR-0018, ratified

`docs/decisions/ADR-0018-provenance-correction-of-synthetic-authority.md` is
**Accepted**, 2026-09-27, at G11-BC-AI, with the approved correction scope
exactly as given:

```
CORRECTABLE_FIELDS = {actor, request_id, recorded_at}
```

`reason` is **not** in it, and the ADR now says why as a property rather than a
preference: the abandonment validates its reason category against the store
before writing, so a category that survived that check is a **fact about what
happened**, not an assertion about who claimed it. That was proved from the
released `_REASON_REQUIRES_RESULT` map — `historical-incomplete-execution` maps
to `False`, meaning "admitted when there is no terminal result", and
CINV-000001 has none. Making it correctable would let an **effect** be disputed
through a mechanism built for an **attribution**.

The ADR gained two tables it did not have: the four things a correction keeps
apart (lifecycle truth/effect; asserted administrative authority; disputed
synthetic provenance; actual-occurrence evidence — a correction touches 2, 3 and
4 only), and the three instants with three names.

## 2. Generation 22, prepared

`provisioning/execution/install-generation-22.sh`, two objects, one coherence
group, **no CREATE**.

| | source | baseline (G21) | target (G22) |
|---|---|---|---|
| 1 | `tools/capability/execution/provenance.py` | `2783c543…0bd6` | `e0f6ffeb…0435` |
| 2 | `tools/capability/cli.py` | `82eb3ffe…425c` | `9459b09f…927f` |

`EXPECTED_LIBRARY_FILES_BASELINE=83`, `TARGET=83`. The count does not move,
because nothing is created.

### The matrix was derived, not assumed

The dependency is real and it runs both ways: `cli.py` imports
`CORRECTABLE_FIELDS`, `FINDINGS` and `INITIATORS` from `provenance.py` **at
parser-build time**, and `provenance.correct_provenance` gained a required
keyword-only argument the old surface does not pass. So **both** intermediates
fail closed, and that was measured rather than argued:

```
provenance new / cli OLD:  TypeError: correct_provenance() missing 1 required
                           keyword-only argument: 'actual_occurrence_at'
cli new / provenance OLD:  TypeError: correct_provenance() got an unexpected
                           keyword argument 'actual_occurrence_at'
```

Both raise at **call time**, before any root is opened or lock taken, so no
`CADM` is allocated and nothing is recorded. The verb is simply unavailable for
the length of the transaction, in either direction. Publication order is
therefore chosen by the rule this repository already follows — the object that
is not an operator surface first, the operator surface **last** — rather than by
which intermediate happens to work.

### The group letter is C, and that is a correction, not a preference

Generation 21's group `P` names *post-execution lifecycle conclusion*, and still
does. Reusing `P` here would have done two wrong things: made a coherence report
name the wrong architecture, and made `conclusion.py` — a `P` member this
generation does **not** move — an undeclared member left behind, which would
have made the installer's own "there is no CARRYOVER" claim false. `C` is added
to the name table; `P` keeps its meaning.

### The installer proves Generation 22, not Generation 21

This was the G11-BC-AF requirement applied to its own successor. The inherited
semantic verifier (`GEN21_PY`, ~270 lines) proved the `CONCLUDED` closure, which
this generation does not deploy. It is replaced by **43 structural properties of
ADR-0018**, read from the parsed source rather than grepped for — among them:

- the correctable set is **exactly** `{actor, request_id, recorded_at}`;
- `reason`, `state`, `previous_state`, `slot_released`, `result_record_id`,
  `cinv`, `lifecycle_state` and `effect` are each proved **absent** from it;
- `actual_occurrence_at` is a required keyword, validated as **its own** instant
  with its own name in its own refusal, and kept distinct in the record from
  both `recorded_at` and `disputed_value`;
- the correction is bound to the subject **member** and that member's digest,
  and a field carried by two members is refused as ambiguous;
- `acquire_capacity`, `transition_locked`, `Mutation(`, `record_terminal_result`,
  `shutil` and `unlink` are all **absent** from `provenance.py`;
- the surface reads each choice list **from the module**, with no choice spelled
  out on it, and exposes no `--force`, `--to` or `--target-state`.

**One verifier, two trees.** `--verify-source` runs it against the reviewed
bytes; `--verify-installed` runs the same function against
`/usr/lib/kyri/python`. A source check and an installed check that could
disagree would be two claims rather than one property — and it means "installed"
asserts the architecture is there, not merely that two hashes matched.

The retained carried-forward checks are labelled as regressions and scoped to a
file this generation republishes (`cli.py`): the `conclude` and `abandon` verbs
are intact, all three administrative mutators still require an explicit
`--store-root`, the compiled-in root is resolved exactly 3 times, `CONCLUDED`
and `ABANDONED` are still declared, and `MAXIMUM_SLOTS` is still 2.

### Carried-forward claims that were no longer true

These were corrected rather than left, and one of them was a defect that would
have halted the installer:

| carried forward | was | now |
|---|---|---|
| `require_operation_shape` | required 6 REPLACE + 1 CREATE, and that the CREATE be `conclusion.py` | 2 REPLACE + 0 CREATE — **the old gate would have halted this installer** |
| object-count comment | "ONE CREATE, so the count moves by one" | NO CREATE, both ends declared as equal |
| matrix preamble | "the seven generation-21 objects" and group P's conclusion rationale | two objects, group C, and why not P |
| rollback note | "five rows on one import chain", ModuleNotFoundError | two coupled rows, the unexpected-keyword TypeError |
| predecessor journal | `/root/kyri-gen20-transaction` | `/root/kyri-gen21-transaction` |
| `--verify-installed` | "the seven MATRIX TARGETS" | the two |
| `EXCLUDED` comment | "carried forward from Generation 22" | from Generation 21 |
| fault-injection variable | `KYRI_GEN20_FAIL_AT` | `KYRI_GEN22_FAIL_AT` |

**Reported, not edited:** `install-generation-21.sh` also carries
`KYRI_GEN20_FAIL_AT`. It is an accepted installer, so it is named here rather
than changed, in the same way the group-A diagnostic defect in Generation 18 is
named in both files.

### The G5 preflight declares it

`cli.py` moves its Generation-21 digest into the baseline list and gains its
Generation-22 digest as a successor, exactly as at G11-BC-E and G11-BC-K.
`provenance.py` **stops being a CREATE** — the truthful shape now that
Generation 20 has published it — becoming a `REPLACE` that keeps `ABSENT` among
its baselines, because a tree predating Generation 20 does not carry the object
at all and one declaration is checked against both kinds of host. That is the
G11-AS case the file already documents. Nothing was relaxed: the checkout must
still carry exactly the declared bytes, and a host that has the object must
still hold a named baseline or the new bytes.

## 3. The Generation-22 installer suite

`tests/test-capability-execution-generation22-installer.sh` — **static by
construction**. Nothing in it runs `--install`, dispatches a governed mutator, or
names a capability runtime. It lifts the verifier out of the installer and runs
it against copies of source files in a temporary directory, which is the whole
point: the suite that reached production on 2026-09-24 did so by driving an
installer's fixtures, and this one has no fixtures to drive.

**21 sabotages, 21 caught**, each by a named property — including the three that
a grep for the name would have passed: a surface that restates the correctable
set, the findings, or the initiators instead of reading them from the module.
That last class is what the G21 drift was, so it is the one the suite exists for.
The harness refuses a sabotage that stops parsing, so "caught" cannot be earned
by a syntax error.

It also proves both intermediates fail closed, in-process, with no store and no
dispatch — and that the installer **states** both, because an interrupted
operator needs to know which broken state the host is in.

**What it does not cover, stated rather than implied:** the transaction journal,
preparation, commit, rollback and recovery are not exercised. Those are host
behaviours of an installer that has not been installed; the operator ceremony is
where they happen.

## 4. The CADM-000004 correction ceremony — prepared, NOT executed

`provisioning/execution/g11-bc-ai-cadm-000004-provenance-correction-ceremony.txt`

**Three corrections, not one.** One record disputes one claim, so three false
claims take three records — `CADM-000005/6/7` for `actor`, `request_id` and
`recorded_at`. Each is create-once per `(subject, field)`, so a partial run
resumes and writes only what is missing.

| block | what it does |
|---|---|
| **A** | observation. Read-only: aggregates, counters, transitions, sequences, the subject verbatim |
| **B** | gates. Read-only, every one refusing rather than reporting |
| **C** | the three corrections. The only part that writes |

Block B's gates: the installed library is wholly Generation 22 (both published
digests **and** six that must not have moved), the installed package is then
**asked what it understands from its own directory**; the runtime aggregate is
`35e33adc…`, Fabric and Trust byte-identical; the five `CINV`/`CRES` records at
their exact digests; `CADM-000004`'s three members at their exact digests, with
`actor: x`, `request_id: y`, the backdated `recorded_at`, `cinv: CINV-000001` and
`reason: historical-incomplete-execution` each found in the record itself; **no
terminal result names CINV-000001**, which is what makes the retained reason the
truthful one; no correction exists yet for any of the three fields, scanned the
way the runtime scans it — from the records, not an index; `CINV-000001`
abandoned, `CINV-000002` abandoned, `CINV-000003` concluded, occupancy **0 of 2**;
counters `000004` / `000000000012`, 9 transitions, 4 administrative records.

Block C names `--store-root` explicitly and then checks the emitted `target`
against the device and inode this ceremony measured **itself** — because the
2026-09-24 escape was invisible to every check that was a check about *text*,
and the one thing that mattered was which object the writer held. One
`--recorded-at` for all three (one operator act, one instant); one
`--actual-occurrence-at 2026-09-24T06:40:43-05:00` for all three (there was one
abandonment). Afterwards: every digest re-checked, no transition, no CMUT
movement, no CRES, no sequence movement, Fabric and Trust byte-identical,
lifecycle and occupancy unchanged, and the three instants proved distinct **in
the durable record** rather than in the emitted summary.

### Two API assumptions in it were wrong, and were found before it shipped

1. It read `recorded_at` from the CLI's emitted JSON. `_emit` does **not** carry
   `recorded_at`. Fixed by reading the **durable** `provenance-correction`
   member instead, which is better anyway: it proves what was written, not what
   was printed.
2. It called `evidence.existing_terminal_result(RootDescriptor, …)`. That
   function takes a `CapabilityStore`. Replaced by reading the result namespace
   directly — two files, one `grep`, repeatable by eye.

Both were found by **executing** the ceremony's fragments rather than reading
them. The read-only fragments were run against production (aggregate unmoved
either side); `INSTALLED_PY` was run against a staged Generation-22 tree and
passes, and against the installed Generation 21 where it correctly **refuses**:
`the installed correctable set is ['actor'], not the three ADR-0018 authority
assertions`. `INSTANTS_PY` was exercised on five documents: the `recorded_at`
record, an `actor` record, collapsed instants, an occurrence equal to the
recording, and a record claiming a reversal — it accepts the first two and
refuses the last three.

Block C itself was **not** executed anywhere. Its semantics are proved by
`tests/test-capability-provenance-multifield.sh`, which drives the identical
three-field CADM-000004 chain in-process against a fixture.

## 5. Tests executed

Production aggregate `35e33adc…` verified before and after every group.

| suite | result |
|---|---|
| `test-capability-provenance-multifield.sh` | **20/20** |
| `test-capability-execution-provenance-correction.sh` | **22/22** |
| `test-capability-execution-generation22-installer.sh` | **all pass**, 21/21 sabotages caught, 43 properties |
| `test-no-production-escape.sh` | pass |
| `test-capability-execution-lifecycle.sh` | 45/45 |
| `test-capability-execution-abandonment.sh` | 26/26 |
| `test-capability-execution-conclusion.sh` | 33/33 |
| `test-capability-execution-mutation.sh` | 38/38 |
| `test-capability-execution-capacity.sh` / `-race.sh` | 31/31, 5/5 |
| `test-static.sh` | 860 pass |
| `test-docs-static.sh` | 993 pass |
| `test-developer-experience.sh` | 141 pass — registration verified both directions |
| `test-capability-execution-g5-preflight.sh` | 36 pass |
| `test-capability-execution-generation-succession.sh` | pass |
| `test-capability-execution-generation13-packaging.sh` | 21 pass |
| `g5-preflight.sh --verify-source` | all checks passed |
| `install-generation-22.sh --verify-source` | all checks passed, 2 REPLACE / 0 CREATE |
| ShellCheck | clean on the installer, both ceremonies, and the new suite |

`install-generation-22.sh --verify` was run and reached its root-only gate:
`the Generation-21 library evidence at /root/kyri-gen21-library-digests.txt is
missing` — it needs root to read `/root`. That is the operator's step and it was
**not** escalated.

### The validator, and the four suites that stop it

`tools/dev/run-validation.sh` halts in **both** modes before it reaches any suite
this checkpoint added:

```
--quick   FAILED: CADM-000001 correction rehearsal (exit 1)   step 43
--full    FAILED: CADM-000001 correction rehearsal (exit 1)   step 67
```

**This is pre-existing and not caused by this checkpoint.** The rehearsals pin
Generation-20 digests and a two-record production store, and the host is at
Generation 21 with four administrative records:

```
REFUSE: /usr/lib/kyri/python/tools/capability/execution/admin.py is
        b4ea351b…7be9, not the reviewed Generation-20 f691f914…5606
FAIL: A PRODUCTION ADMINISTRATIVE RECORD WAS CREATED
```

The second line is the rehearsal counting its byte copy of production against a
stale expected record count — production was **not** written, and the same suite
says so two lines earlier: `the production runtime is byte-identical:
35e33adc…`. It is the G11-BC-AC class of defect (a host-only guard pinned to a
generation the host has left), now in four suites: **CADM-000001 correction
rehearsal**, **CINV-000003 Stage 2 rehearsal**, **CINV-000003 Stage 3
rehearsal**, **Capability mutation target**.

So the validator's own evidence was obtained by **measuring** with those four
neutralised. A copy of the validator was cut into the scratchpad — never
committed, and removed afterwards — with only those four commands replaced by a
stub that still consumes its step. Everything else ran for real:

| mode | executed steps | `FAIL:` lines | `HOST_ONLY_SKIP` | production aggregate |
|---|---|---|---|---|
| `--quick` | **135** | 0 | 0 | `35e33adc…` unmoved |
| full | **160** | 0 | 0 | `35e33adc…` unmoved |

Both new suites ran inside those measurements: quick `[74/…]` multi-field,
`[75/…]` generation-22 installer; full `[98/…]` and `[99/…]`.

**And the declared totals were already wrong.** 132 + 2 suites predicts 134, and
a run prints 135; 157 + 2 predicts 159, and a run prints 160. The missing step is
G11-BC-AH's **`No production escape`**, which I registered without moving either
total — and which no run could have caught, because the validator has not reached
its own closing count since G11-BC-AG. `TOTAL_STEPS` is now **135** and **160**,
read off a run rather than incremented.

## 6. Known risks

1. **`--verify`, `--install`, `--verify-installed` and `--recover` have not run
   against a host.** Only `--verify-source` can run unprivileged. The
   transaction machinery is inherited from an accepted installer and its
   generation-specific constants are checked statically, but the first real
   proof is the operator ceremony.
2. **`--verify-installed`'s `prove_adr0018` call has not been exercised against
   an installed Generation-22 library**, because none exists. The same function
   passing against a staged Generation-22 tree and refusing against the
   installed Generation 21 is the strongest evidence available before
   installation.
3. **Three `CADM`s, three records.** An operator who runs Block C and stops
   after two leaves two of three assertions disputed. The create-once/resume
   behaviour makes re-running safe, and Block B reports which already exist.
4. **The validator cannot complete on this host** until the four stale
   rehearsals are repinned. Every suite it would run is green — measured — but
   until they are repaired, a clean `run-validation.sh` is not obtainable and
   `TOTAL_STEPS` cannot be re-confirmed by an unmodified run.
5. **`reason` stays undisputed by design.** If a terminal result for
   CINV-000001 ever appeared, `historical-incomplete-execution` would stop being
   the truthful category and the exclusion would become a problem. Block B gates
   on exactly that.

## 7. Questions for the reviewer

1. **Group `C`.** Accept the new letter, or require `P` reused with a widened
   name? The letter change is what makes "there is no CARRYOVER" a true claim.
2. **`provenance.py` becoming a `REPLACE` in the G5 declaration.** Accept, or
   prefer the `abandonment.py` precedent of keeping `CREATE` and adding a
   successor hop? Keeping `CREATE` would need `2783c543…` added as a baseline
   anyway, so the shape would be `CREATE` with two baselines including `ABSENT`
   — less truthful, same strength.
3. **Generation-21's `KYRI_GEN20_FAIL_AT`.** Reported, not edited. Correct call?
4. **The correction ceremony's `--actor primary-platform-operator`.** This names
   who records the correction, not who abandoned. Confirm that is the identity
   the reviewer wants on the three records.
5. **Order of operations.** Install Generation 22, get acceptance, then run the
   correction ceremony — or review both together first?
6. **The four stale rehearsals.** Repair them (repin to Generation 21 and to the
   four-record store, the G11-BC-AC way), or leave them and accept that
   `run-validation.sh` cannot complete on this host? I did **not** repair them:
   at G11-BC-AC the repair scope was the reviewer's explicit choice, and this
   brief said to implement only the requested task. Repairing them is the only
   way the validator's closing count is checkable without an instrument.

---

## What was NOT done, per the stop boundary

Generation 22 was not installed. CADM-000004 was not corrected. No lifecycle was
mutated. Nothing was abandoned, concluded, recovered or cleaned. No capability
was executed. Fabric was not renewed and remains expired. `MAXIMUM_SLOTS` is 2.
Trust, Artifact authority and Platform Evidence are untouched. Root Authority was
not mounted. ENG-0006 was not begun.
