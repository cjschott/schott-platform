# ENG-0006-H2B — Envelope Reference/Version Contract Correction

**Date:** 2026-10-16
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `5e34b9dc88021383a1fcde1ac0c316066e3cee9a` (H2A)
**Report-correction commit:** `cca3d31ecf6b5e15ac48e369e0490bdf2a48dd4f`
**Increment type:** Normative contract amendment plus the parser correction it requires.
**Status:** READY FOR REVIEW

---

## 1. The ruling, and what it closed

> An unmonitored CHSTATE must carry an explicitly null envelope reference and an
> explicitly null envelope version. Both fields remain required. For other
> states, both must identify a valid envelope and version.

This resolves **Q-H2A-1**, which H2A recorded and deliberately left standing: an
`unmonitored` state legitimately carried `envelope_id: null` while still being
required to supply a version integer ≥ 1 for an envelope that by definition did
not exist. H2A refused a null version because that is what the schema then said,
and asserted that refusal in a test rather than deciding the question itself.

No authoritative requirement contradicts the ruling. The check and its result
are in §3.

---

## 2. Why the two fields are one fact

The amendment rests on the fields' own declared purpose, not on a preference.

| source | wording |
|---|---|
| `capability-health-envelope.schema.yaml:80-81` | "Supersession chains by version, so 'which envelope was this evaluated against' has an answer after the envelope has moved on." |
| `capability-health-state.schema.yaml:182-183` (pre-amendment) | "The version evaluated against, recorded so a later supersession cannot change what a past assessment meant." |
| `docs/health/worked-examples.md:159` | "Both remain auditable, and **each names the envelope version that produced it**." |

`envelope_version` is therefore *the version of the cited envelope* and nothing
else. With `envelope_id: null` no envelope produced the assessment, so a
non-null version does not merely look odd — it asserts an evaluation that did
not happen. Conversely an envelope named without its version cannot say which
limits produced the verdict once that envelope has been superseded, which is
the exact readability `supersession_rewrites_prior_evaluations: false`
(`:136`) exists to protect.

**No sentinel was introduced, because the platform already forbids that move
for the identical shape.** CHOBS declares `measured_value` required and
conditionally null on a sibling field's value, with the reason stated in the
schema itself: "Null when collection_status is not 'collected'. A failed
collection has no measurement, and **recording a zero would be inventing one**"
(`capability-health-observation.schema.yaml:54-56`, restated at
`docs/health/observation-model.md:52`). Writing `0` or `1` beside a null
envelope would invent a version for an envelope nobody wrote.

Corroborating, the ontology already contemplates the citation being wholly
absent: `platform-model/ontology/relationship-types.yaml:822-823` — "A subject
with no envelope is unmonitored rather than healthy, so **the absence of this
edge** is itself a finding." The edge is CHSTATE → CHENV; an absent edge has
neither target nor target version. And downstream, `capability-selection`
already lists `envelope_id` and `envelope_version` together under
`candidate_health_fields.conditionally_required` (`:178-181`), so it has always
permitted both to be absent as a pair.

---

## 3. Contradiction check — none found

Required by §3 of the brief before amending.

| candidate contradiction | finding |
|---|---|
| A requirement that `envelope_version` be non-null for all states | **None.** The only statements of its purpose are the three in §2, and each ties it to a cited envelope. |
| ENG-0006-C reconciliation | No decision about `envelope_version`. |
| ENG-0006-D implementation plan | One mention, `:678`, listing it among CSEL per-candidate fields — consistent, since CSEL already makes it conditionally required. |
| Guard assertions | `tests/test-capability-health.sh:513` and `:605` require the field to be **present in `required_fields`**. The amendment keeps it there, so both still pass. |
| A new version concept or changed supersession | Neither introduced; declared explicitly as `introduces_new_version_concept: false` and `redefines_supersession: false`. |

---

## 4. The normative amendment

`platform-model/schemas/capability-health-state.schema.yaml` only. One new
declarative block at `:157-181`, placed immediately after
`supersession_rewrites_prior_evaluations` because that is the envelope-citation
neighbourhood of the schema, and following the existing convention for a
declarative sub-block (`withheld_semantics` in the same file, CHENV's
`hysteresis_continuity`).

```yaml
envelope_citation:
  fields:
    - envelope_id
    - envelope_version
  both_fields_always_required: true
  omission_permitted: false
  null_permitted_for_states:
    - unmonitored
  null_required_for_states:
    - unmonitored
  must_be_null_together: true
  must_be_non_null_together: true
  null_id_with_non_null_version: forbidden
  non_null_id_with_null_version: forbidden
  half_citation_permitted: false
  version_without_envelope: forbidden
  sentinel_version_permitted: false
  version_is_of_the_cited_envelope: true
  introduces_new_version_concept: false
  redefines_supersession: false
```

Mapping to the eight required points, in order: (1) and (2) `envelope_id` and
`envelope_version` remain in `required_fields` at `:227` and `:234`,
reaffirmed by `both_fields_always_required`; (3) `null_required_for_states`;
(4) `must_be_non_null_together` with `null_permitted_for_states` restricted to
`unmonitored`; (5) `null_id_with_non_null_version: forbidden`; (6)
`non_null_id_with_null_version: forbidden`; (7)
`sentinel_version_permitted: false`; (8) `version_without_envelope: forbidden`.

The inline comments above both fields in `required_fields` were updated to
point at the block, so a reader arriving at either field finds the pairing rule
rather than half of it.

**No validation suite needed to change to recognise the contract.** Verified
rather than assumed: no meta-schema exists, and no suite asserts an exact
top-level key set for a schema (the only near match,
`tests/test-docs-static.sh:864`, asserts ADR-0010 *text*). All five guard and
schema suites were run against the amended schema **before** the parser was
touched and all five passed. §7's STOP condition was therefore not triggered.

---

## 5. The parser correction

`tools/health/records.py`, `_validate_state`, +22/−10. The pairing is checked
first, before either per-field validator:

```python
if (p["envelope_id"] is None) != (p["envelope_version"] is None):
    raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=kind,
                   field="envelope_version", detail="envelope-citation-pairing")
if state == "unmonitored":
    if p["envelope_id"] is not None:
        raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=kind,
                       field="envelope_id", detail="unmonitored")
else:
    _identifier(kind, "envelope_id", p["envelope_id"],
                "capability-health-envelope", code=E.REFERENCE_MALFORMED)
    _whole(kind, "envelope_version", p["envelope_version"], minimum=1)
```

Ordering is deliberate. Checking the pairing first means no state can reach the
per-field validators holding half a citation, so a null version is never
reported as a malformed *integer* when the real fault is the broken pairing.
`state` is still resolved against the closed enum on the preceding line, so
neither branch can be reached with an unvalidated state.

### Preserved, as §4 of the brief requires

| preserved | evidence |
|---|---|
| Seven-state vocabulary | `HEALTH_STATES` untouched; the matrix in §6 exercises all seven |
| Identifier syntax | `_identifier` unchanged and still used for the non-null case |
| Positive-integer version validation | `_whole(..., minimum=1)` unchanged; `0`, negatives, `True`/`False`, floats and strings all still refused |
| Controlled refusal codes | `tools/health/errors.py` **byte-identical**; 27 codes |
| Explicit-null serialisation | §7 |
| H2 subject binding | `tests/test-health-binding.sh` unmodified and still 87/0 |
| Record immutability | `HealthRecord.__setattr__` untouched |

**`errors.py` was not modified.** `CONDITIONAL_REQUIREMENT_UNMET` is used for
both faults, as the brief prefers: a pairing violation and a non-null citation
on `unmonitored` are both requirements conditioned on another field's value,
which is what that code already expresses for `review_required` under
`insufficient-policy` in the same validator. The two are distinguished by
`detail` (`envelope-citation-pairing` and `unmonitored`), not by a new code.

**No new Health module.** The change is 14 lines inside an existing function.

---

## 6. The pairing matrix

RED fixtures were written from the ruling before the parser changed. Measured
behaviour after the correction, all seven states against all four pairings:

| state | null / null | null / 1 | valid / null | valid / 1 |
|---|---|---|---|---|
| `unknown` | refuse | refuse | refuse | **accept** |
| `unmonitored` | **accept** | refuse | refuse | refuse |
| `insufficient-policy` | refuse | refuse | refuse | **accept** |
| `healthy` | refuse | refuse | refuse | **accept** |
| `degraded` | refuse | refuse | refuse | **accept** |
| `unavailable` | refuse | refuse | refuse | **accept** |
| `withheld` | refuse | refuse | refuse | **accept** |

This is the brief's required matrix exactly, with no cell left to inference.

Also asserted: omission of **either** field, on both a state that permits nulls
and one that does not (omission returns `missing-required-field`, a different
code from the pairing refusal, so "required field" and "required non-null
value" stay mechanically distinct); version `0`, negatives, booleans, floats and
numeric strings; a positive version other than `1`; eight malformed identifiers
each paired with both a valid and a null version; and the full null round-trip.

### Refusals leak nothing

Checked with values distinctive enough for a substring match to mean a real
echo — `-987654321`, `SUPER-SECRET-ENVELOPE-VERSION`,
`CHENV-SUPER-SECRET-IDENTIFIER`, `CHOBS-987654`. An earlier draft of these
assertions used `-1` and `""`, which are worthless here: `-1` is a substring of
the existing `integer-at-least-1` detail and `""` is a substring of everything.
It also briefly used `987654321`, which is a perfectly **valid** version beside
a declared envelope — that assertion was wrong and was removed rather than
accommodated.

---

## 7. Serialisation evidence

Both halves of a null citation survive, and the field keys stay present:

- `record.envelope_id is None` and `record.envelope_version is None`
- `"envelope_id" in record.to_dict()` and `"envelope_version" in to_dict()` — **both present**
- both serialise as explicit `None`, not as missing keys
- the null version survives `json.dumps` / `json.loads`
- re-parsing the serialised form returns an identical record with both nulls intact

This holds structurally, not by accident: `parse()` copies `REQUIRED[kind]`
with a comprehension that does not test for `None`, and both fields are in
`REQUIRED`. Only conditional and optional fields are dropped when null.

---

## 8. RED before GREEN

| run | passing | failing | exit |
|---|---|---|---|
| H2A baseline (HEAD `5e34b9d`) | 474 | 0 | 0 |
| **RED** — schema amended, tests added, **parser untouched** | 579 | **4** | 1 |
| **GREEN** — parser corrected | **589** | **0** | 0 |

The four RED failures covered both directions of the defect: `unmonitored` with
a fully null citation was refused (`field-type-invalid … detail=integer`), and
`unmonitored` with a null id beside version `1` was accepted.

**32 assertion call sites added (65 → 97); 115 more passing assertions
(474 → 589).**

### One assertion was removed, and it was the superseded one

`tests/test-health-records.sh` previously asserted "an unmonitored state with a
null `envelope_version` is refused". That is the exact expectation the ruling
reverses. It was replaced in place by a comment recording what it used to
assert and why it no longer holds, and its **inverse** is now asserted in the
H2B section together with the pairing rule in both directions. Nothing else was
deleted: the diff is +201/−11 on the suite, and the other ten removed lines are
the comment block belonging to that assertion plus a four-line comment reworded
to mention both halves.

Two H2A fixtures also had to start nulling the version alongside the
identifier, because under the amended contract a record with a null id and a
leftover version is not something anyone could legitimately write — it would
have stopped testing what it was written to test. `state_with()` now pairs the
two by default, and every assertion that exercises the pairing rule sets the
version explicitly afterwards, so the rule is never tested through that default.

---

## 9. Mutation tests — the suite detects broken pairing

Each mutation was applied to the corrected implementation in a scratchpad
sandbox built with `git archive`, the suite run with stdout and stderr kept
**separate**, and the implementation restored byte-for-byte afterwards. The
repository working tree was never used as the mutation target.

| # | mutation | result |
|---|---|---|
| 1 | Remove the pairing check entirely | **DETECTED** — 13 failing, exit 1 |
| 2 | Invert the pairing check (`==` for `!=`) | **DETECTED** — 49 failing, exit 1 |
| 3 | Check only the identifier half, leaving the version unpaired | **DETECTED** — 13 failing, exit 1 |
| 4 | Validate the version unconditionally again (H2A behaviour) | **DETECTED** — 6 failing, exit 1 |
| 5 | Admit `0` as a sentinel version | **DETECTED** — 2 failing, exit 1 |

5 is the one that matters most for this amendment: the sentinel the schema now
forbids is the cheapest way to make an `unmonitored` record look well-formed,
and the suite catches it.

---

## 10. Regression verification

### Named suites, by exit code

| suite | exit | passing | failing |
|---|---|---|---|
| `test-health-records.sh` | 0 | 589 | 0 |
| `test-health-binding.sh` | 0 | 87 | 0 |
| `test-capability-health.sh` | 0 | 487 | 0 |
| `test-capability-health-agreement.sh` | 0 | 88 | 0 |
| `test-platform-model.sh` | 0 | 1003 | 0 |
| `test-docs-static.sh` | 0 | 993 | 0 |
| `test-static.sh` | 0 | 873 | 0 |
| `test-capability-fabric.sh` | 0 | 538 | 0 |
| `test-fabric-runtime.sh` | 0 | 8355 | 0 |
| `test-capability-runtime.sh` | 0 | 1089 | 0 |
| `test-developer-experience.sh` | 0 | 141 | 0 |

`test-capability-health-agreement.sh` is the cross-artifact suite and it passes
unchanged, which is the evidence that the amended schema still agrees with
ADR-0013 and the Health documents rather than having drifted from them.

### AC 25 — preserved

`tests/test-fabric-runtime.sh` passes with 8355 assertions, including the AC 25
battery directly: "AC 25: the fabric package was located for inspection (16
modules)", "AC 25: no fabric module imports the health package ([])", "the
fabric runtime evaluates no health state", "absent health input removes
nothing", and the per-increment "creates no health.py" checks for increments
4 through 9. The Fabric still completes every §8 operation with no Health
Runtime.

### Full suite inventory

| | executed | passing | failing |
|---|---|---|---|
| established baseline | 155 | 127 | 28 |
| **with the H2B amendment and correction** | 155 | 127 | **28** |

- newly failing: **none**
- no longer failing: **none**
- **identical membership: YES**, compared name-by-name against the recorded
  28-suite list and not merely by total

**Assertion-count changes accounted for.** No suite was added or removed, so
the suite count is unchanged at 155. Assertion totals moved in exactly one
suite: `tests/test-health-records.sh` from 474 to 589 passing, +32 call sites
(65 → 97). Every other named suite reports the same totals as before this
increment — 87, 487, 88, 1003, 993, 873, 538, 8355, 1089, 141 — which is why
the schema amendment can be said not to have disturbed them rather than merely
not to have broken them.

**The full platform validator remains red, and this increment does not claim
otherwise.** The same 28 suites fail as before, dominated by the generation
installer and helper-ceremony suites carrying the known hard-coded
`REPOSITORY="/opt/schott-platform"` provisioning defect. No baseline failure
was repaired and none was introduced. That debt is untouched and unrelated.

---

## 11. Production isolation

| check | result |
|---|---|
| `/var/lib/kyri/health` | **absent** |
| `/var/lib/kyri/capability` | **absent** |
| `CH*` records under `/var/lib` | **0** |
| `CH*-*.json` written anywhere in the last 6 hours | **0** |
| Health listener or daemon | **0** |
| `.env` files created or committed | **0** |
| Root operations | **none** — no `sudo` was invoked |
| Production Fabric, Trust or Capability mutation | **none** |
| Deployment | **none** |

`/opt/schott-platform` was not moved, replaced, or recreated. The mutation
runs targeted a scratchpad sandbox, never the working tree, and the repository
reported a clean or exactly-three-file status at every checkpoint.

**Still true:** no Health record is produced, consumed, stored, or read by
anything. Nothing outside `tools/health` imports the package — verified — so
H2B remains pure validation logic with no operational surface.

---

## 12. Carried forward, NOT resolved

| item | status |
|---|---|
| **Q-H2A-1** — `envelope_version` on an unmonitored state | **CLOSED by this increment.** |
| **Q-H2A-2** — withheld publication authority | Carried forward. `v1_producer: none`, `publication_authority: deferred-architecture`. Not implemented here. |
| **Q-H2A-3** — evidence-list cardinality for `unknown` / `withheld` | Carried forward. No cardinality change was made; `_id_sequence` still refuses an empty list for all seven states, exactly as before. |
| **Q-H2-1** — `EVALUATED_AGAINST` missing `same_subject_required` | Carried forward. The ontology was not modified. |
| **Q-H2-2** — CHDEG state-citation wording | Carried forward. CHDEG was not modified. |
| **D1–D7** | All carried forward unresolved. **D5 still blocks heartbeat receiving.** |

Also unchanged: no withheld publication semantics were implemented, and no
general evidence-list cardinality change was made, both of which §7 forbids.

---

## 13. Review package

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H2B — amend the CHSTATE envelope-citation contract so the
identifier and version are null together or valid together, and correct the
parser to enforce it. Plus a separate prior commit correcting three count
errors in the H2A report.

**Files Changed:** `platform-model/schemas/capability-health-state.schema.yaml`
(+52/−2); `tools/health/records.py` (+22/−10); `tests/test-health-records.sh`
(+201/−11); the H2A report (correction commit `cca3d31`); this report (new).
`tests/test-health-binding.sh` was **not** needed and was not touched.

**Tests Executed:** RED 579/4 then GREEN 589/0; five pairing mutations each
detected; eleven named suites all exit 0; full inventory 155/127/28 with
identical failing membership; AC 25 battery verified inside
`test-fabric-runtime.sh`.

**Commands Run:** `bash -n` and `shellcheck` on the changed suite; `yaml.safe_load`
on the amended schema; the eleven named suites; direct `parse()` probes building
the 7×4 matrix; `git archive` sandbox builds for the mutation runs with `cmp`
restore verification; the full inventory script; `find`/`pgrep` isolation checks.

**Known Risks:**

1. The amendment adds a declarative block the parser must be kept in step with
   by hand. The suite asserts the block's contents and the behaviour separately,
   so a drift between them fails, but nothing *derives* one from the other.
2. `envelope_citation` is a new top-level key. No meta-schema or key-set guard
   exists today to reject it, which is why the amendment was safe — and equally
   why nothing would have caught a misspelled key. The suite reads the block by
   its exact key names, which is the only thing standing in for that check.
3. The pairing refusal names `envelope_version` as the offending field in both
   directions. That is a judgement: when the version is present and the
   identifier is null, a reviewer might prefer the identifier be named.
   `detail=envelope-citation-pairing` makes the actual fault unambiguous either
   way.

**Architecture Decisions:** none taken beyond applying the ruling. Alternatives
B (a separate assessment version) and C (a sentinel) were rejected on committed
authority, not preference — see §2 — and are recorded as rejected rather than
silently dropped.

**Questions for Reviewer:**

1. Should a meta-schema or key-set guard exist for the schema files, so a
   future misspelled declarative key fails rather than being ignored? Outside
   H2B's authorised scope; raised because this increment relied on its absence.
2. Is naming `envelope_version` in both directions of the pairing refusal the
   preferred reporting, or should the null half be named instead?
3. Q-H2A-2, Q-H2A-3, Q-H2-1 and Q-H2-2 remain open and unaddressed by design.
