# G11-BC-AL — a missing member is a shape, and the matrix comes back

**Date:** 2026-10-02
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `0785e8befa35c42b8f6768fc7f89bcbc3aeb51e6`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — three obligations resolved; Generation 23 prepared and **not installed**. **One new blocker found and reported rather than worked around: the expired Fabric authority masks 14 of the 22 restored gate cases.** Production was not mutated.

---

## 0. The invariant

`7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99`, measured
before and after every executable group and unmoved throughout. Fabric
`a87c2010…12e5` unmoved and **still expired — not renewed**. `CINV-000001`
abandoned, `CINV-000002` abandoned, `CINV-000003` concluded, occupancy 0 of 2,
`cadm-counter 000007`, `cmut-counter 000000000012`, 9 transitions, Generation 22
installed, **Generation 23 not installed**.

## 1. §B — the schema-version question, answered before anything was built

The ruling asked whether the released records already carry enough structure to
tell the two shapes apart. **They do, and no bump is needed.** Proved two ways:

| | `correction_schema_version` | `actual_occurrence_at` |
|---|---|---|
| `CADM-000002` (ADR-0016) | `1` | absent |
| `CADM-000005/6/7` (ADR-0018) | `1` | present |

So **the version discriminates nothing.** The member discriminates **totally**,
and that is structural rather than circumstantial: the ADR-0018 source writes it
in a flat dict literal with no conditional enclosing it — checked by walking the
AST to the `detail` assignment and proving no `If` or `IfExp` is on the path — so
an ADR-0018 record always carries it, and ADR-0016 had no such member to omit.

**`SCHEMA_VERSION_CHANGE_REQUIRED=NO`**, and the smallest reader-side rule is
therefore sufficient. No old record is rewritten, then or ever.

## 2. O1 — the rule, and the one thing it needs ratified

`LATER_SCHEMA_MEMBERS = {actual_occurrence_at: "ADR-0018"}` — closed, a literal,
each member named with the ADR that introduced it. `_compare_for_resume` is its
own function, which is what keeps the two refusal reasons apart; inlined in the
caller they had already drifted into one message.

| situation | before | now |
|---|---|---|
| legacy record, identical request | refused: *different authority* | **resumes**, reporting `actual_occurrence_at: null` |
| legacy record, omitted argument | `TypeError` | the argument is still required; the call is well-formed |
| a member the record **carries** disagrees | refused, naming it | unchanged — still refused, naming it |
| a member absent that **no ADR added** | — | refused on the **schema shape**, with a schema reason |

**The resume now reads the occurrence from the record, not from the request.** For
an ADR-0018 record the two are equal — the comparison has just proved it — so this
is a change of provenance rather than of value: what is reported is what is
*recorded*.

### The narrow return-shape change, which is the reviewer's to ratify

`Correction.actual_occurrence_at: str` → **`str | None`**.

Item 7 of the ruling asked me to stop and propose rather than assume this, so:
**this is the proposal, and it is the only change to the return object.** A legacy
resume has nothing to report there, and the alternatives are worse —

- echoing the caller's value would report `CADM-000002` as holding an occurrence
  **it does not hold**, which is the defect again in a new place;
- an empty string would be a sentinel dressed as data;
- a separate `legacy_shape` field would be more surface than the problem needs.

`cli.py` needs no change: `_emit` serialises the field, so `None` becomes `null`.
**Authorising the Generation-23 installation is the ratification** — nothing is
installed until then, and the installer refuses to publish bytes whose annotation
is anything else.

### RED first

`tests/test-capability-provenance-legacy-compatibility.sh`, 13 cases. **6 failed
against the Generation-22 source and all 13 pass now.** Its legacy fixture is not
a guess: the synthesised shape is checked **key-for-key against production's real
`CADM-000002`**, which it matches exactly — 20 members, one fewer than the modern
shape, and that one is `actual_occurrence_at`.

## 3. Generation 23 — one object, derived

| | source | baseline (G22) | target (G23) |
|---|---|---|---|
| 1 | `tools/capability/execution/provenance.py` | `e0f6ffeb…0435` | `39141cd4…7647` |

**Derived, not assumed.** A direct scan of all 77 installed objects against the
reviewed tree finds **exactly one** difference. Group **L** — a new letter, because
C is multi-field provenance correction and still means that, and reusing it would
have made `cli.py` a C member left behind undeclared. That is the same reasoning
that added C rather than reusing P at G11-BC-AI.

**A single row has a property no earlier generation had: there is no intermediate
publication state at all.** Every generation from 18 onward had to argue about
which half-published combination an interrupted operator would meet. This one
cannot be half-published.

`install-generation-23.sh --verify-source`: **all checks passed**, 1 REPLACE /
0 CREATE, group L, 83 → 83, prefix `gen23-`, **59 properties** — ADR-0018's 43,
still, plus 16 for Generation 23. `tests/test-capability-execution-generation23-installer.sh`
makes **17 sabotages** permanent and catches **17 of 17**, including the four that
matter most: emptying the closed set, admitting a member no ADR added, comparing an
absent member anyway, and turning the shape refusal back into an authority refusal.

Prepared, **not installed**: `provisioning/execution/install-generation-23.sh`,
`provisioning/execution/gen23-operator-ceremony.txt`. Declared in the G5 preflight
as a pending successor, with `e0f6ffeb…` moved into the baseline list.

## 4. O2 — ADR-0018's compatibility section

It said *"No record schema changes. `provenance.py`'s detail members are
unchanged"* while its own §Semantics said `actual_occurrence_at` was new and the
runtime wrote it. **That error is what let the ADR-0016 gap ship unnoticed**, so it
is corrected as four separate statements rather than one that ran them together:

- **no subject record is rewritten** — that is the claim the old wording reached
  for, and it is true;
- **no lifecycle schema changes** — no state, transition, result, `CINV` or `CRES`
  field moves;
- **the provenance-correction detail shape DID gain the member**, with
  `correction_schema_version` staying `1`, so the version does not distinguish the
  shapes and the member's presence does;
- **ADR-0016 records without it remain valid historical records**, untouched.

And handling the older shape is now **a rule rather than an expectation**, naming
`LATER_SCHEMA_MEMBERS` and the generation that publishes it. Historical meaning is
not erased: the correction says what the old text claimed, why it was wrong, and
what it cost.

## 5. O3 — the gate matrix, and the blocker it ran into

`tests/test-capability-cinv-000003-stage-3-gate-matrix.sh` — **74 PASS, 0 FAIL.**
The production-host rehearsal stays **spent** and nothing here makes it executable
again.

### The fixture is assembled, not rewound

A rewind removes the later objects it knows by name, and drifts whenever an
accepted ceremony adds one — it had already drifted twice. This restricts by
**high-water mark**: `CADM` ≤ 2, `CMUT` ≤ 10, `CRES` ≤ 1. Those are facts about the
moment before Stage 3 and they never move, so a record allocated next year is
excluded by the same rule that excludes `CADM-000003`, with nothing edited here.

**The transitions follow from the CMUT mark, not a second list.** Every lifecycle
transition spends exactly one CMUT, and each mutation's intent *names* the
transition it journalled (`target_kind: execution-transition`,
`target_name: CINV-000001.000003`). One fact governs both.

**And it is proved complete by content:** the assembled store reproduces the
accepted pre-Stage-3 aggregate `648066f6…e133a` **exactly**, or the suite refuses
to run at all.

That check earned its place immediately. My first derivation excluded every
transition at sequence ≥ 3 and took `CINV-000002.000003` with it — the 2026-09-20
abandonment, which **predates** Stage 3. The aggregate refused the fixture rather
than letting the matrix run against a store that was not what it claimed.

### BLOCK B gets the library it was reviewed against

Its first gate pins the Generation-20 digests, because Generation 20 is what the
operator ran it against. **That pin is historical evidence and is not edited.** The
reviewed Generation-20 library is materialised from that generation's own pinned
commit and substituted for `INSTALLED`, so the gates measure what they were written
to measure. The sabotage case *"the installed runtime is not Generation 20"* still
exercises that very gate, and passes.

### THE BLOCKER: the expired Fabric authority masks 14 of 22

BLOCK B checks the Fabric authority's validity window **before** anything about the
runtime store. The window has closed since Stage 3 ran, so it refuses there:

```
REFUSE: the authority is not currently supported: admission-window-not-open
REFUSE: the Fabric authority is not currently valid; renew and re-prepare
```

**That is the gate working, not failing.** Per the standing instruction — *if
expired Fabric causes a legitimate gate refusal, stop and report it; do not weaken
an expired-authority assertion* — I did not renew Fabric, did not edit the
ceremony's gate order, and did not give the fixture a synthesised validity window.
The fixture carries the reviewed chain, expired, because that is what the reviewed
chain is.

What the matrix proves today:

| | of 22 |
|---|---|
| present and run | **22** |
| **fail closed** (BLOCK B exits nonzero) | **22** |
| judge rather than crash (no traceback) | **22** |
| **reach their own named refusal** | **8** |
| **masked by the expired authority** | **14** |

The eight that reach their own gate are the generation gate, advertisement expiry,
current eligibility, the Fabric baseline moving, the execution image absent, a
target container existing, and the witness being absent or stale. The fourteen
behind the Fabric gate are listed by name in the suite's own output.

**The masking is measured, not declared.** The suite detects
`admission-window-not-open` from the run itself; it records each masked case as
*not yet proved* rather than passing it; and **if the authority is live and a case
is still masked, that is a failure.** So the moment Fabric is renewed these fourteen
become requirements with **no edit to this suite** — which is the property that
makes reporting the blocker acceptable rather than a quiet deferral.

**`STAGE3_GATE_MATRIX_RESTORED=YES`** as a harness and a fixture;
**8 of 22 fully proved** as refusals today, with a mechanical path to 22.

## 6. Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **138/138**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| `run-validation.sh` (full) | **163/163**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| clean clone at `4b3b66f`, full | **163/163**, 0 `FAIL:`, **18 `HOST_ONLY_SKIP`** |
| GitHub CI at `4b3b66f` | CI, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy — **6/6 success** |

The clean clone's 18 skips are all the intentional pinned-checkout refusal —
`checkout <clone> is not the pinned /opt/schott-platform` — on the historical
generation installers, the four G5 suites, the helper ceremony, the Generation-13
packaging suite, the Fabric evidence-authority suite and the Artifact-authority
suite. Every one ran for real in the host run, which had **0 skips**.

**All three new suites RAN in the clone**, with the same results as on the host:
legacy compatibility 13, Generation-23 installer 52, Stage-3 gate matrix 74 — the
last with its 39 explanatory notes, 14 of which name a masked case. The gate matrix
is host-only because it needs the host's reviewed OBJECTS, not the pinned checkout
path, so a clone on this machine exercises it fully.

Suites, against the real post-correction state: legacy compatibility **13** ·
multi-field **24** · provenance correction **22** · Generation-23 installer
**52** · Stage-3 gate matrix **74** · Stage-3 spent rehearsal **34** ·
no-production-escape **4** · lifecycle **45** · abandonment **26** · conclusion
**33** · mutation **38** · capacity **31** + race **5** · CADM-000001 rehearsal
**32** · Stage-2 rehearsal **31** · mutation target **33** · generation succession
pass · g5 preflight **36** · static **865** · docs-static **993** ·
developer experience **141** · ShellCheck clean on every changed file.

## 7. What remains for ENG-0005 closure

O1, O2 and O3 are resolved as far as this checkpoint can take them. What is left:

1. **Generation 23 installation** — the reviewer's decision, and the ratification
   of the `str | None` widening.
2. **The Fabric decision** — until it is renewed, 14 of the Stage-3 gate cases
   cannot reach their own refusal. This is now a *named* dependency of O3 rather
   than an unknown.
3. **The §36 audit** — fifteen criteria, evidence named for each. Not started, per
   the ruling.
4. **G7** — not entered, per the ruling. Still blocks merge, tag, release and
   Track-B evidence cleanup.

## 8. Questions for the reviewer

1. **The `str | None` widening** — ratify by authorising the Generation-23
   installation, or would you rather see a different representation of absence?
2. **The 14 masked gate cases** — accept the measured-masking arrangement and let
   Fabric renewal complete them, or do you want the fourteen re-provided against a
   fixture carrying a synthesised validity window? I did not do the latter: it
   would mean the gate was no longer judging the reviewed Fabric chain.
3. **Order** — install Generation 23, then renew Fabric, then the §36 audit, then
   G7? Renewal after installation means the gate matrix completes on the first run
   after renewal, with no further work.

---

## What was NOT done

Generation 23 was not installed. No CADM was mutated. No lifecycle was mutated. No
capability was executed. Fabric was not renewed and remains expired. Track-B
evidence was not cleaned. G7 was not entered. The §36 audit was not performed.
Nothing was merged, tagged or released. ENG-0006 was not begun. `MAXIMUM_SLOTS` is
2; Trust, Artifact authority and Platform Evidence are untouched; Root Authority
was not mounted.
