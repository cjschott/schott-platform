# G11-BC-AJ — one finding per field, and four rehearsals that described a host that no longer exists

**Date:** 2026-09-28
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `e76d6d0022cb2f8988282eb10cd74da8eca67532`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — Generation 22 is prepared and not installed; the CADM-000004 ceremony is prepared, corrected, and not executed. **Production was not mutated by this checkpoint.**

---

## 0. The invariant

The governed runtime store was measured before and after every executable group:

```
35e33adc98a777964f56c626b58ff5d6945594946862ec7d6a233be98b276c4f
```

Unmoved throughout, including across both full validator runs and the clean
clone. Fabric `a87c2010…12e5` unmoved and still expired — **not renewed**, and no
expired-authority assertion weakened. After all testing: `CINV-000001` abandoned,
`CINV-000002` abandoned, `CINV-000003` concluded, occupancy **0 of 2**,
`cadm-counter 000004`, `cmut-counter 000000000012`, 9 transitions, `CRES-000002`
`2d908b86…aebf`, Generation 21 installed, **Generation 22 not installed**.

## 1. The finding mapping was wrong, and nothing was looking

The reviewer read ADR-0018 against the prepared ceremony and found the
discrepancy. The ceremony carried

```bash
FINDING=assertion-synthetic
```

and passed it to all three corrections. ADR-0018 fixes the mapping per field:

| disputed_field | disputed_value | finding |
|---|---|---|
| `actor` | `x` | `attribution-not-authorised` |
| `request_id` | `y` | `assertion-synthetic` |
| `recorded_at` | `2026-09-20T20:00:00-05:00` | `assertion-synthetic` |

So `actor` would have been recorded under the wrong category — and a correction
recorded under the wrong finding is itself untruthful provenance, which is the
one thing this verb exists not to be.

**The two findings are not interchangeable.** `attribution-not-authorised` says a
record claims an ACTOR and that actor did not authorise the action; `actor` is
the field whose whole job is to name who acted, so a false one is an unauthorised
attribution whatever literal it holds. `assertion-synthetic` says the value was
never asserted by any authority at all — a literal that reached the record
through a mechanism with no standing. `y` is that, and so is a timestamp copied
out of a test.

**Why nothing caught it.** `tests/test-capability-provenance-multifield.sh` had
the mapping right in its own helper from the start. The ceremony had it wrong.
Neither disagreed with anything it could see, because no test compared the two —
or either to the ADR. The reviewer made that comparison by hand. It is now a
test.

### What changed

`provisioning/execution/g11-bc-ai-cadm-000004-provenance-correction-ceremony.txt`

- one constant per field, `FINDING_ACTOR` / `FINDING_REQUEST_ID` /
  `FINDING_RECORDED_AT`, and `correct_one <field> <value> <finding> <cadm>`;
- the verdict block checks the emitted `finding` against the field's own
  reviewed finding, not a global;
- Gate 0 now reads the three findings the ceremony will pass, refuses any that
  the installed runtime does not admit, and refuses outright if `actor` would be
  recorded as anything but `attribution-not-authorised`. Exercised both ways
  against a staged Generation-22 tree: the correct mapping passes, the collapsed
  one refuses with
  `actor would be recorded under 'assertion-synthetic'; ADR-0018 gives it 'attribution-not-authorised'`.

### The drift check

Three independent statements of one mapping — **the ADR's markdown table**, **the
ceremony's constants**, and **this suite's helper** — each parsed from its own
file and required to agree. It also checks that the ceremony *uses* the constants
(a table nothing reads is decoration), that the three calls allocate
`CADM-000005/6/7`, and that no global `FINDING=` survives anywhere.

Three sabotages, three caught:

| sabotage | caught |
|---|---|
| `FINDING_ACTOR` collapses to `assertion-synthetic` | yes |
| the ceremony passes one global finding again | yes |
| the ADR's table changes under the ceremony | yes |

### Section H, proved on a fixture

The suite now seeds a fixture whose `cadm-counter` is `000003`, so the harness's
abandonment allocates **CADM-000004** and the three corrections land on
**CADM-000005, CADM-000006, CADM-000007** — the identities the ceremony expects,
now a checked claim rather than a hope.

| CADM | field | finding |
|---|---|---|
| CADM-000005 | `actor` | `attribution-not-authorised` |
| CADM-000006 | `request_id` | `assertion-synthetic` |
| CADM-000007 | `recorded_at` | `assertion-synthetic` |

All three: `actual_initiator = unauthorised-test-harness`,
`actual_occurrence_at = 2026-09-24T06:40:43-05:00`, `effect = retained`,
`lifecycle_state = abandoned`, `action_reversed = false`,
`lifecycle_unchanged = true`, `slot_changed = false` — read back from the
**durable records**, not the return values. And a snapshot taken before and after
the whole chain proves no transition, no CMUT movement, no result namespace and
no sequence movement, with the subject's `abandonment` member byte-identical.

**Block C was not executed against production.**

### A correction to the G11-BC-AI report

That report's §4 said "All three are therefore `assertion-synthetic`". That was
wrong, and it was the same error as the ceremony's. The report is left as it
stands — it is the record of what was believed at that checkpoint — and this is
the correction.

## 2. The four stale rehearsals

Each encoded a world that has since moved on. Each is repaired by branching on a
**durable fact**, never by widening a pin. No expected hash was weakened into
"whatever exists"; no historical pin was updated to a current value.

### 2.1 CADM-000001 provenance-correction rehearsal — 32 PASS

**The durable fact:** the correction record exists and is exact
(`CADM-000002/provenance-correction` = `47b977d8…e58e`).

**What was stale, and how.** The suite asserted the spent ceremony refuses *at
the runtime-baseline gate*, and separately asserted it does **not** refuse on the
installed generation. Both were true at Generation 20. The host is at Generation
21, so the ceremony's own Generation-20 pin now fires first.

That pin is **historical evidence of what the operator actually ran against** and
is not edited. What changed is that the suite names the generation gate as the
durable reason it truthfully is — one of a closed, exactly-matched set — and then
measures **both** facts itself rather than reading them out of the refusal text:
the installed `cli.py` is not `90979a02…`, and the store is past the
pre-correction baseline `9374b568…`.

Its three remaining failures were all the same shape: `CADM-000003 does not
exist`, asserted of production and of its own fixture copy. True when
CADM-000002 was the last record; false once the ADR-0017 conclusion wrote
CADM-000003 and the 2026-09-24 escape wrote CADM-000004 — neither of which this
suite has anything to do with. **Naming an identity made every later accepted
ceremony look like damage.** The assertion that was always meant is "this run
wrote nothing", so that is what is measured: the record-name set and the counter
as the run found them, compared at the end. The suite's **subject** keeps its
exact pins — CADM-000001's three members and CADM-000002's finding — because a
pin is the right instrument for a subject.

It also now builds its `correct_provenance` calls from the **installed
signature**, passing `actual_occurrence_at` only where the released verb accepts
it. Without that it would break the moment Generation 22 installs, which is the
staleness this checkpoint exists to end.

### 2.2 CINV-000003 Stage 2 rehearsal — 31 PASS

**The durable facts:** the launch-authorisation is byte-identical
(`885801a1…f31df`) and the later lifecycle proves Stage 2 spent.

Same generation-gate repair as above. Two more:

- **The lifecycle assertion** demanded `launch_authorized` and occupancy 2 of 2 —
  the state Stage 2 left. Stage 3 executed it and ADR-0017 closed it, both
  accepted. It now accepts `launch_authorized` **or** the accepted `concluded`
  closure, and refuses anything else by name. The authorisation record Stage 2
  wrote is pinned either way, and *that* is the durable evidence of what Stage 2
  did; the lifecycle beyond it belongs to the ceremonies that followed.
- **"A repeat resumes"** drove `authorise_launch` again and expected
  `resumed=True`. Against a concluded invocation the released code refuses:
  `CINV-000003 is concluded and is no longer awaiting launch authorisation`.
  Asserting resumption would be asserting a behaviour that no longer exists, so
  the concluded host now proves the **refusal** — by name, as `LaunchRefused`,
  not a crash — and that it wrote nothing. That is the stronger property: the
  closure being respected by the one verb that could otherwise reopen it. The
  resume branch is kept verbatim for an unspent host.

### 2.3 CINV-000003 Stage 3 rehearsal — 34 PASS, and a stated coverage loss

**The durable fact:** `CRES-000002` exact **and** `CINV-000003` concluded.

This is the one where the brief's rule bites hardest, so the cost is stated
plainly rather than glossed.

The suite copied production and **rewound** it to the pre-Stage-3 condition, then
drove the released coordinator over the real protocol. That rewind subtracts a
hand-kept list, checked against a pinned aggregate. It had already been extended
once — at G11-BC-AG, for the conclusion — and the 2026-09-24 escape would have
required extending it again. Each extension rebuilds a store further from
anything that ever existed, which is the drift the rewind's own comment warns
about.

So the question is now asked once, of the durable record: **has Stage 3
happened?** If it has, that substrate is gone and reconstructing it is the wrong
instrument. The suite verifies the **accepted historical result** instead: the
result record and the authorisation by exact digest, that the stored
`result_digest` is the digest the released package produces from the published
payload **on this run**, `outcome_class: completed`, `attempt_number: 1`, the
whole lifecycle journal (`reserved launch_authorized concluded`), the sequence at
2, no `CRES-000003`, and that the installed coordinator still carries the
duplicate-result gate ahead of the provider.

**What spent mode does not cover, said plainly:** the coordinator half driven end
to end, the eight failure paths, the duplicate-result gate against a fixture, and
BLOCK B's gates with their 22-case sabotage matrix. The protocol and the
supervision refusals are covered against purpose-built fixtures by the
supervised-execution and evidence suites, which need no production substrate;
**BLOCK B's gate matrix is not covered anywhere else, and that is the price of
not rebuilding a store that no longer exists.**

The pre-Stage-3 aggregate pin `648066f6…` is untouched and still governs an
unspent host. A half-spent store — a result without the closure, or the reverse —
fails immediately and asks for an operator, because it is neither rehearsable nor
verifiable.

### 2.4 Capability mutation-target rehearsal — 33 PASS

**Not a spent-mode case.** Its two failures were the checkout's own
`correct-provenance` gaining a required `--actual-occurrence-at` under ADR-0018,
which the suite's hard-coded argument list did not pass.

Repaired by reading the required flags **off the checkout's own parser** — the
parser is built, never dispatched — and appending the occurrence only when it is
offered. The subject of that suite is *which store the writer holds*; the
argument list is scaffolding, so it is derived. The next required argument cannot
make it stale again.

Per the brief, no host-generation assumption was changed beyond that, and the
historical implicit-root mutator is **not** executed: the Generation-19
`command_abandon` is called **in process with both openers rebound to stand-ins
that raise before opening anything**, which is the sanctioned form of the class.

## 3. The escape class, audited

`tests/test-no-production-escape.sh` — **PASS**, over 145 suites.

A direct audit of the four repaired suites, run separately:

| check | result |
|---|---|
| every subprocess dispatch of a governed mutator names `--store-root` | 6 of 6 (one deliberate omission, asserted as a usage error) |
| `CAPABILITY_RUNTIME_ROOT` only ever asserted about, never resolved | 5 sites, all assertions |
| a handler called in process has both openers rebound to non-opening stand-ins | 1 of 1 |
| parser assertions build a parser and stop | 7 sites, 0 handler dispatches |
| the historical implicit-root package materialised but never dispatched | confirmed |

**0 failures.**

## 4. Validation — real, committed, no stubs

| run | result |
|---|---|
| `tools/dev/run-validation.sh --quick` | **135/135**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| `tools/dev/run-validation.sh` (full) | **160/160**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| clean clone at `6f8627e`, full | **160/160**, 0 `FAIL:`, **18 `HOST_ONLY_SKIP`** |

**The clean clone's 18 skips are all one thing**, and none is counted as a host
pass: `checkout <clone> is not the pinned /opt/schott-platform` — the intentional
pinned-checkout refusal, on the eleven historical generation installers, the four
G5 suites, the helper ceremony, the Generation-13 packaging suite, the Fabric
evidence-authority suite and the Artifact-authority suite. Every one of them ran
for real in the host run above, which had **0 skips**. The four repaired
rehearsals, the multi-field suite, the Generation-22 installer suite and the
escape guard all RAN in the clone — 32, 31, 34, 33, 24, 50 and 4 PASS, 0 FAIL —
because none of them is pinned to the checkout path.

**A first clean-clone attempt failed at step 66, and the cause was mine.** The
Generation-20 installer hard-codes `REPOSITORY="/opt/schott-platform"`, so even
when the validator runs from a clone that suite inspects the REAL repository —
and I had written this report into it, untracked, while the run was in flight.
Its clean-tree gate refused, correctly: `the working tree is not clean; a
ceremony runs from reviewed bytes only`. The run above was redone with the host
tree committed and clean, and it is the one reported. Worth knowing: a
clean-clone validation is not isolated from the real checkout's working tree.

No scratchpad copy, no stubbed suite, no "measured with these four disabled". The
instrument used at G11-BC-AI to obtain a count is gone; these are the committed
validator against this host and this repository.

Per-suite, from the full run:

| suite | result |
|---|---|
| CADM-000001 correction rehearsal | 32 PASS, 0 FAIL |
| CINV-000003 Stage 2 rehearsal | 31 PASS, 0 FAIL |
| CINV-000003 Stage 3 rehearsal | 34 PASS, 0 FAIL |
| Capability mutation target | 33 PASS, 0 FAIL |
| No production escape | 4 PASS, 0 FAIL |
| Capability provenance multi-field correction | 24 PASS, 0 FAIL |
| Capability execution provenance correction | 22 PASS, 0 FAIL |
| Capability execution generation-22 installer | 50 PASS, 0 FAIL |
| lifecycle / abandonment / conclusion | 45 / 26 / 33 |
| mutation / capacity / capacity race | 38 / 31 / 5 |
| G5 preflight / generation succession | 36 / pass |
| developer experience | 141 |
| static / docs-static | 860 / 993 |
| ShellCheck | clean on every changed file |
| GitHub CI at `77c4ebb` | CI, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy — **6/6 success** |

## 5. Generation 22 — semantically unchanged

`install-generation-22.sh --verify-source`: **all checks passed.**

| required | observed |
|---|---|
| source authority | `646b12799a0b5438d1d346f56a9a9a9f9e65299a` |
| matrix | 2 REPLACE / 0 CREATE |
| group | C |
| baseline → target count | 83 → 83 |
| transaction prefix | `gen22-` |
| ADR-0018 verifier | 43 properties |
| sabotages caught | 21 of 21 |
| production mutation | none |

`git diff 646b127 HEAD -- tools/capability/` is **empty**: no runtime source
moved, and the installer needed no semantic change.

## 6. Known risks

1. **Stage 3's spent branch loses BLOCK B's gate matrix on this host**, as set
   out in §2.3. It is the one piece of coverage not recovered elsewhere.
2. **Spent-mode branches are exercised on one side only here.** Every one of the
   four takes its spent path on this host; the unspent paths are retained
   verbatim but are not run by any host we have. They are the original code, not
   new code, which is why they were kept rather than rewritten.
3. **Generation 22 has still not been installed anywhere**, so
   `--verify-installed`'s `prove_adr0018` has never run against an installed
   Generation-22 library.
4. **The ceremony's Gate 0 was exercised against a staged tree, not an installed
   one** — for the same reason.

## 7. Questions for the reviewer

1. **Stage 3's coverage loss.** Accept it as the price of not rebuilding a store
   that no longer exists, or should BLOCK B's gate matrix be re-provided against
   a purpose-built fixture in a later checkpoint?
2. **The generation gate as a durable spent reason.** Two ceremonies now refuse
   because they pin Generation 20 and the host is at 21. I treated that pin as
   historical evidence and named the refusal rather than editing the pin —
   confirm that reading.
3. **Signature-driven calls in rehearsals.** Two suites now build their
   `correct-provenance` arguments from the installed/checked-out parser so that
   installing Generation 22 cannot make them stale. Acceptable, or would you
   rather they pin a generation and be updated deliberately?

---

## What was NOT done, per the stop boundary

Generation 22 was not installed. CADM-000004 was not corrected — Block C was
never executed, against production or anything else. No lifecycle was mutated.
Nothing was abandoned, concluded, recovered or cleaned. No capability was
executed. Fabric was not renewed and remains expired. `MAXIMUM_SLOTS` is 2.
Trust, Artifact authority and Platform Evidence are untouched. Root Authority was
not mounted. ENG-0006 was not begun.
