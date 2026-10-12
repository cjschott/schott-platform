# G11-BC-AK — the correction is in production, and what ENG-0005 still owes

**Date:** 2026-10-01
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `cbc26b66e2ea7bb4ac2699bd6023a9e3889364d9`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the correction is verified by content. **ENG-0005 cannot formally close yet**; six obligations are named below. Production was not mutated by this checkpoint.

---

## 0. The accepted post-correction baseline

```
7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99
```

This supersedes `35e33adc…6c4f`. Measured before and after every executable
group in this checkpoint and unmoved throughout. Fabric `a87c2010…12e5` and
Trust `53605e4e…b63f` unmoved; **Fabric remains expired and was not renewed.**

| | before the correction | now |
|---|---|---|
| runtime aggregate | `35e33adc…6c4f` | **`7dfb34e6…2e99`** |
| administrative records | 4 | **7** |
| `cadm-counter` | `000004` | **`000007`** |
| `cmut-counter` | `000000000012` | `000000000012` — **unmoved** |
| transitions | 9 | 9 — **unmoved** |
| `CINV` / `CRES` sequences | 3 / 2 | 3 / 2 — **unmoved** |
| installed runtime | Generation 21 | **Generation 22** |
| lifecycle | abandoned / abandoned / concluded | unchanged |
| occupancy | 0 of 2 | unchanged |

## 1. The correction, verified by content rather than taken on trust

### The three records

| CADM | `disputed_field` | `disputed_value` | `finding` |
|---|---|---|---|
| `CADM-000005` | `actor` | `x` | `attribution-not-authorised` |
| `CADM-000006` | `request_id` | `y` | `assertion-synthetic` |
| `CADM-000007` | `recorded_at` | `2026-09-20T20:00:00-05:00` | `assertion-synthetic` |

**The per-field mapping the reviewer required at G11-BC-AJ is what production
carries.** All three: `subject_cadm CADM-000004`, `subject_member abandonment`,
`subject_digest c6af9f8a…ef0e5`, `cinv CINV-000001`,
`actual_initiator unauthorised-test-harness`,
`actual_occurrence_at 2026-09-24T06:40:43-05:00`, `effect retained`,
`lifecycle_state abandoned`, `action_reversed false`,
`lifecycle_unchanged true`, `slot_changed false`, and one shared
`recorded_at 2026-10-01T16:14:55-05:00` — one operator act, one instant.

`CADM-000007` carries three distinct instants, which is what ADR-0018 exists for:
the disputed `2026-09-20T20:00:00-05:00`, the observed
`2026-09-24T06:40:43-05:00`, and the recording `2026-10-01T16:14:55-05:00`.

### Nothing else moved, and that is proved by reconstruction

Removing exactly `CADM-000005`, `CADM-000006` and `CADM-000007` from a byte copy
and rewinding `cadm-counter` to `000004` reproduces

```
35e33adc98a777964f56c626b58ff5d6945594946862ec7d6a233be98b276c4f
```

**exactly.** So the correction's whole mutation set was three append-only records
plus one counter: no transition, no CMUT, no result, no sequence movement,
nothing unexplained. This is the G11-BC-AG discipline applied to its own
successor, and it is the strongest statement available that the verb did only
what it claims.

### Everything it disputes is byte-identical

All thirteen accepted records re-verified against their pinned digests:
`CADM-000001`'s three members, `CADM-000002`'s finding
(`47b977d8…e58e`), `CADM-000003`'s conclusion, `CADM-000004`'s three members
(including the disputed `abandonment`, `c6af9f8a…ef0e5`), the three `CINV`
records and both `CRES` records. **The subject was not written to.** Lifecycle and
occupancy read from the released code: `{CINV-000001: abandoned,
CINV-000002: abandoned, CINV-000003: concluded}`, **0 of 2**.

### Generation 22 is installed, and it is the architecture

Both published objects are at their reviewed digests
(`e0f6ffeb…0435`, `9459b09f…927f`). The installer's own ADR-0018 property
verifier, run against `/usr/lib/kyri/python`, reports **43 of 43 properties, 0
refusals** — so "installed" means the architecture is there, not that two hashes
matched.

## 2. Two more pins the correction turned stale

Both repaired; neither was a weakening.

**The mutation-target fixture** named one record to remove — the incident's own
`CADM-000004` — and set the counter to 3. The three corrections *of that record*
then sat above it, and the released integrity check refused the whole fixture:
`the CADM counter stands at 3 behind recorded 7`. That is the second drift in
this builder, so the rewind is now **derived and shared** with
`uncorrected_fixture`, which was repaired for the same thing at G11-BC-AG. It
asserts its own result both ways: the highest surviving record must equal the
counter, and the incident's record must be gone. Removing the corrections with
their subject is the truthful choice — they are *about* `CADM-000004`, and keeping
them would leave three findings pointing at nothing.

Its "exactly four administrative records" tripwire now compares against what the
run itself found, per the G11-BC-AJ rule.

**The CADM-000001 rehearsal's resume case** failed for a different reason, and it
is not test staleness. See obligation 1.

## 3. Post-correction validation

| run | result |
|---|---|
| `tools/dev/run-validation.sh --quick` | **135/135**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| `tools/dev/run-validation.sh` (full) | **160/160**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |

Per-suite, against the real post-correction state: no-production-escape 4 ·
multi-field 24 · provenance correction 22 · Generation-22 installer 50 ·
CADM-000001 rehearsal 32 · Stage 2 rehearsal 31 · Stage 3 rehearsal 34 ·
mutation target 33 — **0 FAIL in every one.** ShellCheck clean on both changed
files.

## 4. Remaining ENG-0005 obligations

These are what closure turns on. Six, ordered by what blocks what.

### O1 — an ADR-0016-era correction cannot be resumed by the ADR-0018 verb

**Severity: fail-closed, but untruthful in its reason. Runtime defect in an
installed generation.**

`CADM-000002` was written under ADR-0016 and carries no `actual_occurrence_at`.
ADR-0018 added that member to the written detail, and the create-once conflict
check compares **every** recorded field. So against the installed Generation 22
there is no call that resumes it:

```
supply --actual-occurrence-at  ProvenanceRefused: CADM-000001/actor is already
                               corrected under different authority
                               (actual_occurrence_at None, not '2026-09-20T18:54:33-05:00')
omit it                        TypeError: missing 1 required keyword-only argument
```

Both write nothing, so no record can be damaged. But **the refusal names the
wrong cause**: the authority is identical, and only the schema differs. In the
provenance subsystem specifically, a refusal that misdescribes itself is the class
of defect this whole arc exists to remove.

**Not repaired here.** The repair is in `provenance.py`, which is installed, so it
means a **Generation 23** the reviewer has not authorised. Reproduced read-only
against a same-filesystem byte copy; production untouched. The CADM-000001
rehearsal now asks the prior record which schema it carries and asserts whichever
behaviour is correct for the pair in front of it — resume where the schemas agree,
a fail-closed refusal naming `actual_occurrence_at` where they do not — rather
than pretending either way.

**Options for the reviewer.** (a) Generation 23: exclude absent members from the
conflict comparison, or compare only members both records carry, and name the real
cause in the refusal. (b) Bump `correction_schema_version` and compare
version-for-version. (c) Accept it as a documented consequence, since the only
affected record is already corrected and nothing needs re-correcting — but then
ADR-0018 must say so.

### O2 — ADR-0018's compatibility claim contradicts its own semantics

**Severity: documentation, with a schema-versioning question inside it.**

§Compatibility says: *"No record schema changes. `provenance.py`'s detail members
are unchanged; only which `disputed_field` values are admissible moves."* §Semantics
says `actual_occurrence_at` *"is new in this ADR"*, and the released source writes
it into every correction detail. The source agrees with §Semantics, so
§Compatibility is wrong.

Underneath it is a real decision: **`correction_schema_version` is `1` on both
shapes.** `CADM-000002` has no `actual_occurrence_at`; `CADM-000005/6/7` do. A
reader cannot tell them apart by version, which is also the mechanism behind O1.

### O3 — the Stage-3 BLOCK B gate matrix, deliberately deferred

**Severity: test debt, knowingly taken at G11-BC-AJ with reviewer visibility.**

Stage 3's spent branch gave up the coordinator half driven end to end, the eight
failure paths, the duplicate-result gate against a fixture, and **BLOCK B's
22-case sabotage matrix**. The first three are covered against purpose-built
fixtures elsewhere. The gate matrix is **not covered anywhere**, and recovering it
means building a synthetic pre-Stage-3 store rather than rewinding production.

### O4 — the engineering ledger understates ENG-0005 by two tracks

**Severity: documentation, and it is a T22 deliverable.**

`docs/history/v1.0-engineering-ledger.md` still records ENG-0005 as *"Track A
non-executing foundation complete locally; pending integration. Execution blocked
pending the rootless execution prerequisite (Track B) and a separately authorised
adapter."*

The adapter is built, installed through **Generation 22**, and has executed a real
capability in production: `CINV-000003` ran on 2026-09-22 and produced
`CRES-000002`. T22 requires the ledger to record the adapter as implemented. The
row is corrected in this checkpoint; §5 below says exactly what it now says.

### O5 — reviewer gate G7 has not been entered

**Severity: blocking. This is the one that decides closure.**

The first-adapter plan's G7 blocks *"cleanup of retained Track-B evidence, and any
merge, tag, or release"*, before T22. It has not been entered. Retained Track-B
evidence is still on the host (`/data/kyri/trackb-test`, and the root-owned
generation evidence under `/root`), which is correct — G7 is what authorises its
cleanup, and nothing here touched it.

**ENG-0005 cannot close, be merged, or be tagged until G7 is entered and
accepted.**

### O6 — no criterion-by-criterion §36 audit exists for this arc

**Severity: blocking for a formal closure claim.**

The first-adapter plan's §8 makes the design's §36 criteria *the* acceptance
criteria, fifteen of them, each mapped to a task. Individual suites plainly cover
individual criteria, but **no document in this arc walks the fifteen and names the
evidence for each.** I did not produce one here and will not assert coverage I have
not evidenced: a keyword survey is not an audit. Closure needs that walk, and it is
a checkpoint of its own.

### Standing, and not defects

- **Two suites are deliberately disarmed and retained as evidence**: the
  CINV-000002 reclamation rehearsal (unregistered on purpose) and the
  Generation-20 installer suite (disarmed at G11-BC-AH, registered and green).
  Both are evidence of what they did, and removing them is a G7 matter.
- **Fabric authority is expired.** A separate decision, as instructed. Nothing
  here renewed it and no expired-authority assertion was weakened.

## 5. The closure assessment

**ENG-0005 cannot formally close yet.** Not because the engineering is unfinished
in the places that matter most — the adapter executes, the lifecycle closes
properly, both escapes are preserved with their effects retained and their
provenance corrected append-only, and the test class that allowed them is shut —
but because closure has a defined gate and two of its inputs are missing.

**What is genuinely done.**

- The execution transition works end to end in production and is evidenced:
  `CINV-000003` executed, produced `CRES-000002`, and closed as `concluded` under
  ADR-0017.
- Both accidental production-test escapes are preserved as historical evidence,
  not erased. Truthful lifecycle effects retained; false authority corrected
  append-only, under the per-field findings ADR-0018 fixes.
- The escape class is closed by a sabotage-tested static guard over all 145
  suites, and the two suites that caused the escapes are disarmed and kept.
- Generations 20, 21 and 22 are installed and accepted, each verified against the
  installed bytes rather than against a number in a file.
- Both validators pass against the real post-correction state, with no stubs and
  no host-only skips.

**What closure still requires.**

1. **G7** entered and accepted — O5. Blocks merge, tag, release and evidence
   cleanup.
2. **The §36 walk** — O6. Fifteen criteria, evidence named for each.
3. **A ruling on O1** — Generation 23, a schema-version change, or an accepted
   documented consequence.
4. **ADR-0018's §Compatibility corrected** — O2.
5. **A decision on O3** — recover the gate matrix, or accept the debt in writing.

O4 is addressed in this checkpoint.

**Recommended order.** O2 and O4 are documentation and cost little. O1 is the only
one that may need runtime change, so it should be ruled on next, because a
Generation 23 would move the installed baseline again and everything downstream
pins it. O6 is the long pole and is best done once O1 is settled. G7 last, with
Fabric renewal as the separate decision after it — renewing an expired authority
before the closure gate would put a live authority behind an unclosed increment.

## 6. Questions for the reviewer

1. **O1** — which of the three options? My recommendation is (a) Generation 23:
   compare only members both records carry, and name the real cause. It is a small,
   closed change to one function, and it makes the refusal truthful, which matters
   more here than in most places.
2. **O3** — recover the Stage-3 gate matrix against a synthetic store, or accept
   the debt with a written rationale?
3. **O6** — should the §36 walk be its own checkpoint (G11-BC-AL), and should it be
   evidence-gathering only, or may it add missing coverage where it finds gaps?
4. **G7** — anything you want in hand before it is entered, beyond the above?

---

## What was NOT done

Fabric was not renewed and remains expired. ENG-0006 was not begun. No lifecycle
was mutated; nothing was abandoned, concluded, recovered or cleaned; no capability
was executed. No runtime source changed — `provenance.py` and `cli.py` remain the
reviewed Generation-22 bytes at `646b127`, and O1 was reported rather than
repaired. Retained Track-B evidence was not touched. `MAXIMUM_SLOTS` is 2. Trust,
Artifact authority and Platform Evidence are untouched. Root Authority was not
mounted.
