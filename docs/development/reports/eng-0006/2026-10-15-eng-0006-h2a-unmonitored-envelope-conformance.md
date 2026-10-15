# ENG-0006-H2A — CHSTATE Unmonitored Envelope Conformance

**Date:** 2026-10-15
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `79832b9a298ce4323b388e9dd04a0937d898788a`
**Increment type:** Conformance correction. One validator branch, one test section.
**Status:** READY FOR REVIEW

---

## 1. What was wrong

The committed CHSTATE schema permits a null envelope citation for exactly one
state. The H1 validator refused that form, and accepted its contradiction.
Measured at the starting HEAD, with the correction reverted:

| payload | H1 behaviour |
|---|---|
| `state: unmonitored`, `envelope_id: null` | **REFUSED** — `reference-malformed` |
| `state: unmonitored`, `envelope_id: "CHENV-0001"` | **ACCEPTED** |

So the only coherent form of an `unmonitored` state was unrepresentable, and
the one form that contradicts its own state was the only one allowed. An
`unmonitored` state citing an envelope asserts the existence of the very thing
the state says does not exist.

This is a **confirmed schema/implementation contradiction**, not an ambiguity.
The schema's permission is unconditional in its own terms and the
implementation contradicted it in both directions.

### Root cause

`tools/health/records.py`, `_validate_state`, validated the citation
unconditionally:

```python
_identifier(kind, "envelope_id", p["envelope_id"],
            "capability-health-envelope", code=E.REFERENCE_MALFORMED)
```

`_identifier` requires a well-formed `CHENV-NNNN` string. `None` is not one, so
the null form could never pass, and nothing anywhere constrained the state and
the citation to agree.

---

## 2. Required field vs required non-null value

The distinction the brief asks for, kept separate throughout:

- **`envelope_id` is a required FIELD, for every one of the seven states.** It
  appears in `required_fields` with no condition attached. Omitting it is a
  missing required field in every case, `unmonitored` included.
- **Its VALUE is conditional.** Null is permitted — and, per §3, obligatory —
  for `unmonitored`, and must be a well-formed CHENV identifier otherwise.

An explicit null is therefore a *supplied value*, not an omission. Both are
asserted separately in the suite: the null form is accepted, and the same
record with the key deleted is refused.

### Null survives parsing and serialisation — verified

The brief flagged the risk that `parse()` drops nulls. It does not, for this
field, and the reason is structural:

```python
fields = {field: payload[field] for field in REQUIRED[kind]}      # unconditional
for field in (*CONDITIONAL.get(kind, ()), *OPTIONAL.get(kind, ())):
    if payload.get(field) is not None:                            # dropped when None
        fields[field] = payload[field]
```

`envelope_id` is in `REQUIRED["capability-health-state"]`, so it is copied by
the first comprehension, which does not test for `None`. Only conditional and
optional fields are dropped when null. Verified directly rather than argued:
`record.envelope_id is None`, `"envelope_id" in record.to_dict()` is `True`,
the serialised value is an explicit `None`, and re-parsing the serialised form
round-trips byte-identically with the null intact. Four assertions.

---

## 3. The state-by-state envelope matrix

Built from the normative sources before implementation, as required. Every row
cites the wording it rests on. No row was decided by implementation
convenience.

The governing clause, `capability-health-state.schema.yaml:179-181`, sits
directly above `envelope_id` in `required_fields`:

> Null only when state is `unmonitored`, which is precisely the case of having
> no envelope to evaluate against.

"Only when" constrains the other six states on its own. What makes the
`unmonitored` row an **obligation** rather than a mere permission is that
`unmonitored` is defined by the envelope's absence, in six independent places, each quoted verbatim below:

| source | exact wording (verified at these lines) |
|---|---|
| CHSTATE `state` enum, :221-223 | "No envelope declared at all, so health is not assessable. Distinct from unknown: one means 'we have not looked', the other 'there is nothing to look against'." |
| `ADR-0013-capability-health-plane.md`:290 | "\| `unmonitored` \| No envelope declared; health is not assessable. \| No \|" |
| `ADR-0013-capability-health-plane.md`:278 | "**A subject with no envelope is `unmonitored`, not healthy.** There is nothing" |
| `docs/health/health-states.md`:11 | "\| `unmonitored` \| No envelope declared at all; health is not assessable. \| No \| **Inert** \|" |
| `docs/health/health-states.md`:51 | "**`unmonitored`** — there is nothing to know *against*. No envelope has been" |
| `docs/health/operational-envelope.md`:102 | "**A subject with no envelope is `unmonitored`, not healthy.** There is nothing" |
| `capability-health-envelope.schema.yaml`:71 | `absent_envelope_means: unmonitored` |

Given that definition, a non-null citation on an `unmonitored` state is
self-contradictory, so the permission to be null is also a requirement to be.

| state | `envelope_id` | field present | authority |
|---|---|---|---|
| `unknown` | non-null CHENV | yes | governing clause; gloss is about observations, not the envelope |
| `unmonitored` | **null** | yes | the six sources above |
| `insufficient-policy` | non-null CHENV | yes | **stated directly**: "An envelope exists but a metric it should govern has no declared threshold" |
| `healthy` | non-null CHENV | yes | governing clause |
| `degraded` | non-null CHENV | yes | **presupposed**: "Outside the envelope on at least one dimension" |
| `unavailable` | non-null CHENV | yes | **presupposed**: "heartbeat stale beyond its declared threshold" — a declared threshold is an envelope |
| `withheld` | non-null CHENV | yes | governing clause only; see Q-H2A-2 |

Three of the six non-null rows are independently supported by their own glosses
rather than resting on the governing clause alone.

---

## 4. The correction

`tools/health/records.py` only. 16 insertions, 2 deletions, one branch:

```python
if state == "unmonitored":
    if p["envelope_id"] is not None:
        raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=kind,
                       field="envelope_id", detail="unmonitored")
else:
    _identifier(kind, "envelope_id", p["envelope_id"],
                "capability-health-envelope", code=E.REFERENCE_MALFORMED)
```

`state` was already resolved against the closed enum on the preceding line, so
the branch cannot be reached with an unvalidated state value.

### `errors.py` was not modified

No justification is needed because no change was made. The existing
`CONDITIONAL_REQUIREMENT_UNMET` is the accurate code: this is a requirement
conditioned on another field's value, which is exactly what that code already
expresses for `review_required` under `insufficient-policy` in the same
validator. The refusal vocabulary remains at 27 codes.

### H2's citation validation needed no change

`validate_citations` already skips a null citation (`if value is None: continue`),
and `envelope_id` is declared there as a non-list citation. A null envelope on
an `unmonitored` state therefore demands no supplied CHENV record, which is
correct — there is no envelope to supply. The 87 assertions of
`tests/test-health-binding.sh` pass unchanged, which is the evidence that the
two layers compose rather than an assumption that they do.

---

## 5. RED before GREEN

Fixtures were written against the normative matrix and run before the validator
was touched.

**RED — at the starting HEAD, tests added, implementation untouched:** exit 1,
465 passing, **5 failing**:

```
capability-health-state refused the permitted state member 'unmonitored'
capability-health-state accepts every permitted state member (7)
state 'unmonitored' refused its permitted envelope form (null)
state 'unmonitored' refuses the forbidden envelope form: accepted
an unmonitored state with a null envelope was refused
```

Both directions of the defect appear, including the pre-existing
every-permitted-member loop, which the contradiction had been silently failing
to exercise for `unmonitored`.

**GREEN — after the correction:** exit 0, **474 passing, 0 failing**.

### One pre-existing fixture was adjusted, and why

The suite's "accepts every permitted state member" loop built each state from
the valid CHSTATE fixture, which carries a real envelope. Under the correction
the `unmonitored` member needs a null citation to remain otherwise-valid, so
the loop now sets it — the same pattern it already used to keep
`insufficient-policy` valid by setting `review_required`. Without it the loop
would have stopped testing "is this member accepted" and started re-testing the
matrix asserted separately. No assertion was deleted or weakened.

---

## 6. Sabotage checks — both directions

Each sabotage was applied to the corrected implementation, the suite run, and
the implementation restored and re-verified byte-for-byte against a pre-image
copy.

| # | sabotage | result |
|---|---|---|
| 1 | Drop the non-null refusal, so `unmonitored` may cite an envelope | **DETECTED** — 10 failing, exit 1 |
| 2 | Revert to H1: the citation is required non-null for every state | **DETECTED** — 3 failing, exit 1 |
| 3 | Control: let *any* state carry a null citation | **DETECTED** — 6 failing, exit 1 |

1 is the "accepts a contradictory non-null envelope" direction and 2 the
"rejects a legitimate null envelope" direction, both required by the brief. 3
confirms the tests pin the permission to `unmonitored` specifically rather than
merely tolerating nulls anywhere.

---

## 7. Validation

### The changed suite

`tests/test-health-records.sh` — `bash -n` clean, `shellcheck` clean.

| | passing | failing | exit |
|---|---|---|---|
| at HEAD `79832b9`, before this increment | 431 | 0 | 0 |
| **RED** — tests added, implementation untouched | 465 | **5** | 1 |
| **GREEN** — correction applied | **474** | **0** | 0 |

**43 assertions added.** The RED run executed 470 of them: the four nested
round-trip assertions sit inside the `try` block whose `parse()` call was the
one being refused, so they could not run until the correction landed.
431 + 43 = 474.

### Targeted regressions — all by exit code, not by reading output tails

| suite | exit |
|---|---|
| `test-health-records.sh` | 0 |
| `test-health-binding.sh` | 0 |
| `test-capability-health.sh` | 0 |
| `test-capability-health-agreement.sh` | 0 |
| `test-capability-fabric.sh` | 0 |
| `test-fabric-runtime.sh` | 0 |
| `test-static.sh` | 0 |
| `test-docs-static.sh` | 0 |
| `test-platform-model.sh` | 0 |
| `test-developer-experience.sh` | 0 |
| `test-capability-runtime.sh` | 0 |

These eleven are the suites that reference `tools.health` or guard its file set,
plus the wiring and schema suites.

### Full inventory — measured on both sides

The previously recorded 28-suite membership list was not recoverable, so rather
than compare against a remembered list, the full inventory was run **twice** in
one pass: once with the correction and the new tests stashed away (reproducing
the behaviour at `79832b9`), and once with them applied. The working tree was
verified restored byte-for-byte between the two with `cmp`.

| | executed | passing | failing |
|---|---|---|---|
| baseline, correction reverted | 155 | 127 | 28 |
| **with the H2A correction** | 155 | 127 | **28** |

- newly failing: **none**
- no longer failing: **none**
- **identical membership: YES**

**The full platform validator is NOT green, and this increment does not claim
it is.** 28 suites fail, exactly as they did before this work, and that debt is
untouched and unrelated — the failing set is dominated by the generation
installer and helper-ceremony suites carrying the known hard-coded
`REPOSITORY="/opt/schott-platform"` provisioning defect. The complete failing
set is recorded verbatim:

```
test-artifact-authority.sh
test-capability-cinv-000002-reclamation-rehearsal.sh
test-capability-execution-bb-helper-ceremony.sh
test-capability-execution-bc-e-helper-ceremony.sh
test-capability-execution-g5-authority.sh
test-capability-execution-g5-build-context.sh
test-capability-execution-g5-ceremony.sh
test-capability-execution-g5-preflight.sh
test-capability-execution-generation5-installer.sh
test-capability-execution-generation6-installer.sh
test-capability-execution-generation7-installer.sh
test-capability-execution-generation8-installer.sh
test-capability-execution-generation9-installer.sh
test-capability-execution-generation10-installer.sh
test-capability-execution-generation11-installer.sh
test-capability-execution-generation12-installer.sh
test-capability-execution-generation13-installer.sh
test-capability-execution-generation13-packaging.sh
test-capability-execution-generation14-installer.sh
test-capability-execution-generation15-installer.sh
test-capability-execution-generation16-installer.sh
test-capability-execution-generation17-installer.sh
test-capability-execution-generation18-installer.sh
test-capability-execution-generation19-installer.sh
test-capability-execution-generation20-installer.sh
test-capability-execution-helper-ceremony.sh
test-fabric-evidence-authority.sh
test-fabric-renewal-chain-rehearsal.sh
```

No baseline failure was repaired, and none was newly introduced.

---

## 8. Open questions — recorded, NOT resolved

Three adjacent contradictions were found while building the matrix. None is
touched by this increment, because each would require an architecture decision
rather than a conformance fix, and the brief forbids inventing restrictions for
behaviour the sources do not specify.

### Q-H2A-1 — `envelope_version` on an unmonitored state

`envelope_version` is a required field with **no null permission declared**,
glossed "The version evaluated against, recorded so a later supersession cannot
change what a past assessment meant." An `unmonitored` state now legitimately
carries `envelope_id: null` — yet must still supply a version integer ≥ 1 for
an envelope that by definition does not exist.

The correction deliberately leaves this refusing null, because that is what the
schema says, and a test asserts it. But the resulting record claims a version
of nothing. The options are to permit null for `unmonitored` symmetrically with
`envelope_id`, to define a sentinel, or to accept the meaningless integer and
say so in the schema. **Not resolvable without a reviewer ruling.**

### Q-H2A-2 — `withheld` with no envelope is unrepresentable

The governing clause permits null only for `unmonitored`, so a `withheld` state
must cite a real envelope. But withholding is a publication decision about a
subject, and nothing requires that subject to have an envelope. Since `state`
holds one value, "withheld *and* no envelope declared" has no representable
form.

Low urgency, and deliberately not resolved here: the same schema declares
`withheld_semantics.v1_producer: none` and `derivable_from_observations: false`,
so nothing in this release emits `withheld` at all. It should be settled before
a producer is authorised.

### Q-H2A-3 — the evidence list is required non-empty for every state

`_id_sequence` refuses an empty `derived_from_observation_ids` with
`field-empty`, for all seven states. The schema declares the field required and
glosses it "A state that cited nothing could not be re-checked, which would
make it an opinion", but declares no explicit non-empty constraint. For
`unmonitored` it is arguable either way — a subject may be observed yet have no
envelope to evaluate against, or may have neither.

**Observed only. No code was changed and no test was added**, since the
increment is envelope conformance and this is a separate field.

### Carried forward unchanged

- **Q-H2-1 and Q-H2-2** remain unresolved. No authorisation was given to
  resolve them and none was taken.
- **D5** remains unresolved and still blocks heartbeat receiving.
- The baseline validation debt is unchanged; see §7.

---

## 9. Scope and isolation

**Files changed — three:**

| file | change |
|---|---|
| `tools/health/records.py` | +16 / −2. The one conditional branch in `_validate_state`. |
| `tests/test-health-records.sh` | the state/envelope matrix section, plus the two-line fixture adjustment of §5. |
| `docs/development/reports/eng-0006/2026-10-15-eng-0006-h2a-unmonitored-envelope-conformance.md` | this report. |

**Not touched:** `tools/health/errors.py` (§4), `tools/health/__init__.py`, every
schema, every ADR, every doc under `docs/health/`, the Fabric, the selection
path, and `tests/test-health-binding.sh`.

**No schema was changed.** The implementation was moved to the schema, which is
the correct direction for a conformance defect — the schema is the authority
and was already right.

**Production isolation — verified after the work:**

- `/var/lib/kyri/health` — absent.
- `/var/lib/kyri/capability` — absent.
- `CH*` records under `/var/lib` — **0**.
- `CH*-*.json` files written anywhere in the last three hours — **0**.
- No root operation was performed. `/opt/schott-platform` was not moved,
  replaced, or recreated. No `.env` file was created, read, or committed.

**Still true, unchanged by this increment:** no Health record is produced,
consumed, stored, or read by anything. H2A is pure validation logic.

---

## 10. Review package

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H2A — reconcile CHSTATE `unmonitored` envelope behaviour
with the committed schema and architecture.

**Files Changed:** `tools/health/records.py` (+16/−2);
`tests/test-health-records.sh` (matrix section + 2-line fixture adjustment);
this report (new).

**Tests Executed:** see §7. `tests/test-health-records.sh` RED 465/5 then GREEN
474/0; `tests/test-health-binding.sh` 87/0 unchanged; three sabotages each
detected; two full 155-suite inventories, baseline and corrected.

**Commands Run:** `bash tests/test-health-records.sh`,
`bash tests/test-health-binding.sh`, `bash -n` and `shellcheck` on the changed
suite, direct `parse()` probes with and without the correction,
`git stash push`/`pop` with `cmp` restore verification, the two-sided inventory
script, `find`/`sed`/`grep` for the normative extraction and isolation checks.

**Known Risks:**

1. Q-H2A-1 is a live inconsistency this increment leaves standing by design: an
   `unmonitored` state carries a version integer for a non-existent envelope.
2. The matrix's six non-null rows rest on the governing clause's "only when".
   Three are independently corroborated by their own glosses; `unknown`,
   `healthy`, and `withheld` are not. If the reviewer reads "only when" as
   permissive rather than exhaustive, the `withheld` row is the one that moves
   — see Q-H2A-2.
3. The refusal code for the new branch is `conditional-requirement-unmet`,
   which is a reuse judgement. It matches the existing `review_required`
   precedent in the same validator, but a reviewer may prefer a dedicated code
   — that would require modifying `errors.py`, which this increment did not.

**Architecture Decisions:** none taken. One conformance correction applied in
the direction the schema already specified; three contradictions recorded as
open questions rather than resolved.

**Questions for Reviewer:**

1. **Q-H2A-1** — how should `envelope_version` behave on an `unmonitored`
   state? Permit null symmetrically, define a sentinel, or document the
   meaningless integer?
2. **Q-H2A-2** — is `withheld` with no envelope a form that must be
   representable before a `withheld` producer is authorised?
3. **Q-H2A-3** — should `derived_from_observation_ids` remain required
   non-empty for `unmonitored`?
4. Is `conditional-requirement-unmet` the right refusal code, or should a
   dedicated code be added to `errors.py`?
