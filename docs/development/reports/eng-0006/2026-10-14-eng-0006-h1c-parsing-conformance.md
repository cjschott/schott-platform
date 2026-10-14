# ENG-0006-H1C — Health record parsing conformance

**Date:** 2026-10-14 · **Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `870ad1f991804deb13ecc46e39b8a51402283783`

**RESULT: REVIEW_REQUIRED.**

Two questions, two different answers — which is why the brief's instruction not
to assume either was defective was the right one.

| Investigation | Finding |
|---|---|
| **A — timestamps** | **NO DISCREPANCY.** No normative source imposes a timestamp grammar on Health, every value the implementation accepts is a genuine offset-bearing instant, and "strict RFC 3339" is not achievable with `datetime` at all. **No code change.** |
| **B — decimal strings** | **PROVEN DISCREPANCY.** `Decimal()` accepts the IEEE specials, surrounding whitespace and Python underscore separators. A non-finite threshold makes the future evaluator **raise** rather than decide, or renders a dimension unconditionally satisfied. **Corrected.** |

*VERIFIED* marks a fact measured here; *NOT SPECIFIED* marks silence in the
normative sources; *RECOMMENDATION* marks my judgement.

---

## 1. Verified starting state

| Check | Result |
|---|---|
| Branch | `arch/eng-0006-health-runtime` |
| HEAD at entry | `870ad1f991804deb13ecc46e39b8a51402283783` — matched |
| Remote | aligned at the same commit |
| Ancestry | `870ad1f` ← `1eece19` ← `05cb92e` |
| Worktree at entry | clean: 0 modified, 0 untracked |
| Production Fabric | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| Production Capability Runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| Production Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |
| `/var/lib/kyri/health` | absent · `CH*` records: 0 |
| Python | 3.12.3 |

---

## 2. The normative timestamp contract

**Searched: the six Health schemas, ADR-0013, ADR-0019, every document under
`docs/health/`, and every standard under `docs/standards/`.**

*VERIFIED:* **no normative source imposes a timestamp grammar on a Health
record.** The only matches inside the Health schemas are unrelated — the
envelope's `instant` *aggregation kind*, and prose in the heartbeat and state
schemas about **which** timestamp may drive freshness, not how one is written.

### The platform does require RFC 3339 — in scopes that exclude Health

*VERIFIED by reading each standard's own Scope section:*

| Standard | Says | Scope | Governs Health? |
|---|---|---|---|
| `evidence-standard.md:117` | "Timestamps are RFC 3339 with an explicit offset. Naive timestamps are rejected: a time without a zone is not a time." | "every record under `platform-model/evidence/`" | **No** |
| `verification-drift-standard.md:58` | `evaluated_at` — RFC 3339 with offset | `platform-model/verifications/`, `drift-rules/` | **No** |
| `entity-lifecycle-standard.md:64` | `timestamp` — RFC 3339 with explicit offset | every entity under `platform-model/` — and **"It does not define… runtime health."** | **No, by name** |
| `operational-metadata-standard.md:122` | "Use RFC 3339 format." | machine-readable records **under `platform-model/`** | **No** — Health records live in a store, not there |
| `confidence-freshness-standard.md` | the four freshness states | confidence/freshness **values** | Inherited for states; **says nothing about grammar** |
| `capability-route.schema.yaml:131` | `types: rfc3339-with-offset` | the route's `overlap_window` | **No** — a Fabric record |

`entity-lifecycle-standard.md` is the decisive one: it has the widest scope of
any candidate and **explicitly disclaims runtime health**.

### What the Fabric enforces, for comparison

*VERIFIED:* `tools/fabric/admission.py:360` `_aware()` checks `tzinfo` on a
**`datetime` object** — `REASON_NAIVE_INSTANT = "timestamp-carries-no-offset"`.
It performs **no string-grammar validation at all**, because YAML has already
parsed the value. H1 receives strings, so the two are not comparable surfaces.

### Contract, as established

> **Health timestamps must be offset-aware instants. The string grammar is NOT
> SPECIFIED.**

This is exactly what H1 implements, and what the H1 report declared as a
strengthening where the schema is silent.

---

## 3. Timestamp test matrix

*VERIFIED against the implementation at `870ad1f`.* "Contract" classifies each
case against the normative sources, not against the implementation.

| Value | Result | Contract |
|---|---|---|
| `2026-10-13T09:00:00-05:00` | ACCEPTED | offset-aware → accepted |
| `2026-10-13T14:00:00+00:00` | ACCEPTED | offset-aware → accepted |
| `2026-10-13T14:00:00Z` | ACCEPTED | offset-aware → accepted |
| `2026-10-13T09:00:00+05:30` | ACCEPTED | offset-aware → accepted |
| `2026-10-13T09:00:00.123456-05:00` | ACCEPTED | offset-aware → accepted |
| `2026-10-13T09:00:00.1234567890-05:00` | ACCEPTED | **not specified** — RFC 3339 permits any fractional length |
| `2026-10-13T09:00:00` | **refused** | no offset → rejected |
| `2026-10-13` | **refused** | date only, no offset → rejected |
| `2026-10-13 09:00:00-05:00` | ACCEPTED | **not specified** — RFC 3339 §5.6 permits a space separator by agreement |
| `2026-10-13t09:00:00-05:00` | ACCEPTED | **not specified** — RFC 3339 is case-insensitive for `T` |
| `20261013T090000-0500` | ACCEPTED | **not specified** — basic ISO 8601 form; **not** RFC 3339 |
| `2026-W42-2T09:00:00-05:00` | ACCEPTED | **not specified** — ISO week date; **not** RFC 3339 |
| `2026-286T09:00:00-05:00` | **refused** | ordinal date — Python declines it |
| `2026-10-13T09:00:00-05:00 ` (trailing space) | **refused** | — |
| ` 2026-10-13T09:00:00-05:00` (leading space) | **refused** | — |
| `2026-02-30T09:00:00-05:00` | **refused** | invalid calendar date |
| `2026-13-01T09:00:00-05:00` | **refused** | invalid month |
| `2026-10-13T25:00:00-05:00` | **refused** | invalid hour |
| `2026-10-13T23:59:60-05:00` | **refused** | **RFC 3339 EXPLICITLY PERMITS a leap second** — see below |
| `2026-10-13T09:00:00-25:00` | **refused** | invalid offset |
| `2026-10-13T09:00:00+5:00` | **refused** | malformed offset |
| `""`, `"   "`, `"now"` | **refused** | — |

### Two findings that settle Investigation A

**Every accepted value is a genuine, offset-bearing instant.** The divergences
from strict RFC 3339 are exactly two — the basic/compact form and the ISO week
date — and both denote a real moment with a real offset. **There is no value the
implementation accepts that is not a timestamp.** No demonstrable defect.

**"Enforce strict RFC 3339" is not achievable here.** RFC 3339 §5.8 permits
`23:59:60` for a leap second; Python's `datetime` cannot represent second 60 and
refuses it. So mandating RFC 3339 would mean *accepting* a value the standard
library cannot hold, and would require a hand-written parser and a leap-second
representation — to gain nothing, because the implementation is already
*stricter* than RFC 3339 on that point and no normative source asks for it.

**RECOMMENDATION: retain offset-awareness. No code change.** The brief's
instruction applies directly: *"Do not invent a stricter timestamp grammar merely
because it is conventional"*, and *"If it requires only offset awareness, retain
that contract unless an independently demonstrable defect exists."* None exists.

---

## 4. The normative decimal-string contract

*VERIFIED quotations:*

- **CHENV schema, line 153–155:** "A decimal string compared as an exact decimal,
  never a binary float. A threshold that compares differently on two hosts is not
  deterministic." → `condition_value_representation: decimal-string`
- **ADR-0019, Numeric representation:** "A **decimal string**, compared as an
  exact decimal. Not a binary float: `0.1` must not depend on representation, and
  a threshold that compares differently on two hosts is not deterministic.
  Integers are decimal strings with no fractional part."
- **ADR-0019, Rounding:** "**None is required, by construction.** This grammar
  performs no division, no averaging and no interpolation."
- **CHENV schema, lines 58–60:** `null_policy_scope: per-metric`,
  `absent_threshold_means: insufficient-policy`,
  **`absent_threshold_never_means: healthy`**
- **ADR-0013, line 281:** the absence of a policy produces an explicit "we have
  not defined this", **"never a favourable default."**

### The four questions, distinguished as the brief requires

| Question | Answer | Authority |
|---|---|---|
| **Decimal-string syntax** | **Required.** A bare decimal numeral. Whitespace and underscore separators are not part of one. | `condition_value_representation: decimal-string` |
| **Finite numeric value** | **Required.** A threshold exists to be compared against a measurement; a special cannot be. | ADR-0019 "compared as an exact decimal" + ADR-0013's no-favourable-default rule + `absent_threshold_never_means: healthy` |
| **Range restrictions** | **NOT SPECIFIED — and none imposed.** A 401-digit limit and `1e999999` are accepted. | silence; the brief forbids inventing one |
| **Canonical representation** | **NOT SPECIFIED.** `1e3` and `1000` are both accepted and denote the same threshold. Left alone. | silence |

**Exponent notation is permitted.** Nothing forbids it, `Decimal("1e3")` is
exactly 1000, and rejecting it would be a formatting restriction without
authority.

---

## 5. Decimal test matrix

*VERIFIED against the implementation at `870ad1f`, before correction.*

| Value | Before | Contract | After |
|---|---|---|---|
| `0`, `0.1`, `-0.1`, `1.25`, `2000`, `32` | ACCEPTED | finite decimal → accepted | ACCEPTED |
| `-0` (signed zero), `+1` | ACCEPTED | finite decimal → accepted | ACCEPTED |
| `.5`, `5.` | ACCEPTED | finite decimal → accepted | ACCEPTED |
| `1e3`, `1E3`, `1.5e-3`, `1.5E+3` | ACCEPTED | permitted; not specified against | ACCEPTED |
| 401-digit integer | ACCEPTED | no range restriction declared | ACCEPTED |
| `1e999999`, `1e-999999` | ACCEPTED | **finite** — `Decimal` carries the exponent | ACCEPTED |
| **`NaN`, `-NaN`, `+NaN`, `nan`, `NAN`** | **ACCEPTED** | **rejected — not a decimal value** | **refused** |
| **`sNaN`, `-sNaN`** | **ACCEPTED** | **rejected** | **refused** |
| **`Infinity`, `-Infinity`, `+Infinity`, `infinity`, `inf`, `-inf`, `Inf`** | **ACCEPTED** | **rejected** | **refused** |
| **`" 1"`, `"1 "`, `" 1 "`, `"1\n"`, `"\t1"`** | **ACCEPTED** | **rejected — not decimal-string syntax** | **refused** |
| **`1_000`** | **ACCEPTED** | **rejected — a Python literal convenience, not decimal syntax** | **refused** |
| `1,000`, `0x10`, `1/2`, `one`, `""`, `"   "` | refused | rejected | refused |
| `--1`, `1.2.3`, `1e`, `e3`, `+`, `-`, `.`, `1e1.5` | refused | rejected | refused |

### Why a non-finite threshold is a proven defect, not a style preference

*VERIFIED by measurement.* A measured latency of `5000` against each threshold,
under Python's default decimal context:

| Threshold | `gt` | `ge` | `lt` | `le` | `eq` | Consequence |
|---|---|---|---|---|---|---|
| `2000` | True | True | False | False | False | a real threshold: violation detected |
| `NaN` | **RAISE** | **RAISE** | **RAISE** | **RAISE** | **RAISE** | **the evaluator raises — not a verdict at all** |
| `-NaN` | **RAISE** | **RAISE** | **RAISE** | **RAISE** | **RAISE** | same |
| `sNaN` | **RAISE** | **RAISE** | **RAISE** | **RAISE** | **RAISE** | same |
| `Infinity` | False | False | True | True | False | never violated, whatever was measured |
| `-Infinity` | True | True | False | False | False | always violated, whatever was measured |

A `NaN` threshold does not merely produce a wrong answer — **it produces no
answer**, because `InvalidOperation` propagates out of the comparison. An
`Infinity` threshold produces an answer that ignores the measurement entirely.

Either way the dimension **looks governed and cannot yield an honest finding** —
which is precisely the favourable default ADR-0013 forbids and
`absent_threshold_never_means: healthy` names, wearing a declared policy's
clothes. H1 would have let such an envelope into the store.

---

## 6. Explicit versus unspecified behaviour

| Behaviour | Status |
|---|---|
| Timestamps must be offset-aware | **explicit** (by inheritance of the platform's naive-timestamp prohibition, and H1's declared strengthening) |
| Timestamp string grammar | **NOT SPECIFIED** |
| Timestamp canonical form | **NOT SPECIFIED** — `20261013T090000-0500` and `2026-10-13T09:00:00-05:00` are both accepted |
| Leap-second notation | **NOT SPECIFIED** for Health; refused because `datetime` cannot represent it |
| Threshold must be decimal-string syntax | **explicit** |
| Threshold must be finite | **explicit**, by three converging clauses |
| Threshold precision / magnitude / range | **NOT SPECIFIED — deliberately unrestricted** |
| Threshold canonical form | **NOT SPECIFIED** — `1e3` and `1000` both accepted |
| Exponent notation | permitted; nothing forbids it |

---

## 7. Proven discrepancies

**One.** `_decimal_text()` accepted values that are not finite decimal
thresholds: fourteen spellings of the IEEE specials, five whitespace variants,
and Python's underscore separator. **Twenty cases**, each demonstrated.

**None in `_instant()`.**

---

## 8. RED-before-GREEN evidence

The failing test was written **before** the correction and derives its expected
results from the quoted clauses in §4, not from the module.

| Stage | Exit | PASS | FAIL |
|---|---|---|---|
| **RED** — against the unchanged `870ad1f` implementation | **1** | 406 | **24** |
| GREEN interim — after the first correction | 1 | 428 | 2 |
| **GREEN** — final | **0** | **431** | **0** |

The 24 RED failures: **14** non-finite specials accepted, **6** non-decimal
syntax forms accepted, **4** overflow and propagation sites.

### Two interim failures, and what each turned out to be

**One was an implementation bug I introduced and the test caught.** My first
grammar used `^…$` with `re.match`. In Python **`$` also matches just before a
trailing newline**, so `"1\n"` passed the anchored match and would have reached
the store as a threshold with a newline in it. Now matched with `fullmatch`,
which anchors the whole string, with a comment recording why `^…$` is wrong here.

*A probe of my own nearly hid this.* I tested the pattern against `'1\\n'` in a
shell heredoc — backslash-then-`n`, not a newline — saw `False`, and briefly
concluded the regex was fine. The suite, which uses a real newline, disagreed and
was right.

**The other was a wrong expectation in my own test.** I asserted `1e999999` must
be refused "as non-finite". It is **finite**: `Decimal("1e999999")` is
`Decimal("1E+999999")` and `is_finite()` is `True`, because a `Decimal` carries
its exponent rather than converting. Refusing it would have been a magnitude
restriction no normative source declares — exactly what the brief forbids. The
value moved to the accepted set with the reason recorded in the test.

---

## 9. Exact implementation changes

**One function in one file.** `tools/health/records.py`, `_decimal_text()`:

```python
_DECIMAL_TEXT = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
...
    if not _DECIMAL_TEXT.fullmatch(value):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail="decimal-string")
    parsed = Decimal(value)            # unchanged, still exact
    if not parsed.is_finite():
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail="finite-decimal")
```

| Property | Status |
|---|---|
| New refusal code added | **none** — `FIELD_TYPE_INVALID` with a declared `detail` was sufficient, so **`tools/health/errors.py` is untouched** |
| Rejected values echoed in a refusal | **no** — the refusal carries code, kind, field and a constant detail; asserted by the suite |
| Fallback or coercion introduced | **none** — every path either returns the original string or refuses |
| Partially valid record from invalid input | **impossible** — validation completes before construction, unchanged from H1 |
| Fields governed | every `entry_condition` / `exit_condition` value on **CHENV** and the quoted condition on **CHDEG** — both propagation sites tested |
| `_instant()` | **unchanged** |

---

## 10. Regression validation

*VERIFIED. Actual exit codes.*

| Suite | Exit | PASS | FAIL | Before H1C |
|---|---|---|---|---|
| `test-health-records.sh` | **0** | **431** | 0 | 374 — +57 |
| `test-capability-health.sh` | **0** | 487 | 0 | 487 — unchanged |
| `test-capability-health-agreement.sh` | **0** | 88 | 0 | 88 — unchanged |
| `test-platform-model.sh` | **0** | 1003 | 0 | 1003 — unchanged |
| `test-docs-static.sh` | **0** | 993 | 0 | 993 — unchanged |
| `test-static.sh` | **0** | 872 | 0 | 872 — unchanged |
| `test-capability-fabric.sh` | **0** | 538 | 0 | 538 — unchanged |
| `test-fabric-runtime.sh` | **0** | 8355 | 0 | 8355 — unchanged |
| `python3 -m py_compile` | **0** | — | — | compiles |
| ShellCheck | **0** | — | — | clean |

**All six families retain their parsing and serialisation guarantees** — the
valid fixtures still parse, immutability is intact, and
`parse → to_dict → parse` still round-trips losslessly for all six.

**AC 25 intact:** 21 mentions, **20 assertions passing**.

**H1B's allowlist still satisfied:** `tools/health` holds exactly
`__init__.py`, `records.py`, `errors.py`.

---
## 11. Complete suite failure-membership comparison

*VERIFIED by a complete 154-suite inventory using **exit codes**. The full
validation driver halts at its first failure, so the per-suite sweep is the only
way to obtain complete membership.*

| | Suites | Passing | Failing |
|---|---|---|---|
| Established baseline | 153 | 125 | **28** |
| After H1 + H1B | 154 | 126 | **28** |
| **After H1C** | **154** | **126** | **28** |

| Comparison against the established 28-suite baseline | Result |
|---|---|
| Newly failing | **0** |
| No longer failing | **0** |
| Membership | **identical** |

**A note on how this measurement was taken.** A first sweep was launched before
two late edits — the stale-comment corrections in §9 and one added boundary
assertion — so it would have measured a tree that then changed. **It was
discarded and the sweep re-run against the final tree**, because an inventory
that straddles an edit is not an inventory of anything. The numbers above are
from the clean run.

**The full platform validator is not claimed green.** It is not: 28 failures
remain and it exits 1. Their root causes remain unestablished, the previous
environmental 18/10 split remains withdrawn, and the `__pycache__` hypothesis
remains unsupported. **No unrelated failure was repaired.**

---

## 12. Production isolation evidence

*VERIFIED, before and after.*

| Check | Result |
|---|---|
| `/var/lib/kyri/health` | **does not exist** |
| Production `CH*` records | **0** |
| Committed `CH*` records | **0** |
| Health daemon or listener | **none** — 0 Python listeners |
| Production Fabric digest | **unchanged** |
| Production Capability Runtime digest | **unchanged** |
| Production Trust digest | **unchanged** |
| Existing production record rewritten | **none** |
| Root operations | **none** |
| Deployment | **none** |

The suite remains pure in-memory parsing: no temporary directory, no fixture on
disk, nothing to clean up.

---

## 13. Remaining ambiguities

*NOT SPECIFIED. Recorded, not resolved.*

| # | Ambiguity | Effect today | Why not resolved here |
|---|---|---|---|
| **M1** | **Timestamp canonical form.** `2026-10-13T09:00:00-05:00`, `20261013T090000-0500`, `2026-10-13 09:00:00-05:00` and `2026-W42-2T09:00:00-05:00` are four spellings of instants that H1 accepts, two of which are not RFC 3339. | Two immutable records could carry different strings for the same instant. | No normative source states a Health timestamp grammar, and the brief forbids inventing a stricter one. A decision would belong in ADR-0013 or a schema. |
| **M2** | **Threshold canonical form.** `1e3` and `1000` are both accepted and denote the same threshold. | Same shape of concern, one layer down. | ADR-0019 requires exactness of *comparison*, not of *spelling*. Rejecting exponents would be a formatting restriction without authority. |
| **M3** | **Fractional-second precision.** `…09:00:00.1234567890-05:00` is accepted; `datetime` truncates to microseconds on parse, though H1 stores the string unchanged. | A future evaluator parsing the stored string would see a truncated instant. | Not specified. Harmless in H1, which stores and never computes; it is a real question for H4's freshness arithmetic. |
| **M4** | **Leap seconds.** RFC 3339 §5.8 permits `23:59:60`; `datetime` cannot represent it, so H1 refuses it. | A conformant RFC 3339 instant is rejected. | Accepting it needs a representation `datetime` does not have. Flagged so a future reviewer does not mistake this for an oversight. |

**M1 and M2 share a shape**, and whether the platform wants canonical
representations for Health records at all is one decision rather than two.
*RECOMMENDATION:* decide it once, in ADR-0013, rather than per field.

---

## 14. Recommendation on H1 final acceptance

*RECOMMENDATION: accept H1 as final, with H1C applied.*

| Question | Answer |
|---|---|
| Timestamps | **No discrepancy.** The contract is offset-awareness; the grammar is unspecified; every accepted value is a genuine offset-bearing instant; strict RFC 3339 is unachievable with `datetime` and is required by nothing that governs Health. No change was made, and none should be. |
| Decimal strings | **Discrepancy proven and corrected.** Twenty cases that were not finite decimal thresholds are now refused, with three converging normative clauses behind the rule and a measured demonstration that a non-finite threshold makes the evaluator raise or renders a dimension unconditional. |
| Scope | One function, one file. `errors.py` untouched — no new refusal code was needed. No ADR, schema, ontology, guard suite, driver or CI change. No new Health module. H1 was not expanded into contextual validation or derivation. |
| Regression | All eight required suites exit 0; the other seven at unchanged counts. All six families keep their parsing, immutability and round-trip guarantees. AC 25 intact at 20 assertions. H1B's allowlist still satisfied. |
| Baseline | 28 failures, membership identical, zero introduced. |

**Three carry-forwards, none blocking:** U1's known contextual gap (a
contextually invalid CHSTATE still parses — H10 closes it), M1/M2 canonical
representation, and M3 fractional precision, which H4 will need to settle before
it computes freshness from a stored string.

**One process observation worth keeping.** Both defects found during this
increment were found *by the tests*, not by inspection: the `$`-matches-before-a-
newline bug, and my own wrong expectation that `1e999999` overflows. A probe I
wrote by hand asserted the opposite of the truth in the first case, because I
tested backslash-`n` instead of a newline. The suite disagreed with me and was
right both times.

## Related

- [ENG-0006-H1 record models](2026-10-13-eng-0006-h1-health-record-models.md)
- [ENG-0006-H1B guard transition](2026-10-14-eng-0006-h1b-guard-transition.md)
- [ADR-0019: The Health Condition and Hysteresis Grammar](../../../decisions/ADR-0019-health-condition-grammar.md)
- [ADR-0013: The Capability Health Plane](../../../decisions/ADR-0013-capability-health-plane.md)
