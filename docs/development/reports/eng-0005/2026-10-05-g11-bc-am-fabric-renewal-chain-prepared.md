# G11-BC-AM — the minimum renewal, and the fourteen cases it unmasks

**Date:** 2026-10-05
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `8052ec9e11c6062a4805e0a36e3a59accbf6f0e1`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the chain is prepared, rehearsed and **not written**. Against it the Stage-3 matrix reaches **22/22 intended refusals, 0 masked**. Production Fabric, runtime and Trust were not mutated.

---

## A. Production, rehydrated read-only

| | measured |
|---|---|
| branch / HEAD | `arch/eng-0005-execution-transition` / `8052ec9e…` |
| working tree | clean, equal to `origin` |
| installed `provenance.py` | `39141cd4…7647` — **Generation 23 is installed** |
| installed `cli.py` | `9459b09f…927f` — unchanged, as Generation 23 required |
| installed objects | 77 |
| runtime aggregate | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| Fabric aggregate | `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` |
| Trust aggregate | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |
| released `fabric validate` | `status: reported`, **findings: []** |
| Root Authority | not mounted |

**Heads, derived from supersession rather than from the highest number:** every
advertisement, instance and route forms a single chain where each record names
its predecessor, and nothing names `CADV-000007`, `CINST-000006` or
`CROUTE-0006` — so those three are the heads. Selections carry no `supersedes`
at all; `CSEL-000004` is the selection of record for this request class.

| namespace | records | sequence | head |
|---|---|---|---|
| advertisement | 7 | 7 | **CADV-000007** |
| instance | 6 | 6 | **CINST-000006** |
| route | 6 | 6 | **CROUTE-0006** |
| selection | 4 | 4 | **CSEL-000004** |

## B. Why the current authority fails — from the evaluator, not from dates

The released verifier, at the real wall clock, asked exactly what BLOCK B asks:

```
evaluated_at: 2026-10-05T15:46:11-05:00
supported:            False
reason:               admission-window-not-open
eligibility_reasons:  []
```

`eligibility_reasons` is empty because the refusal happens *before* eligibility
is consulted: `verify_selected_evidence` checks the instance's admission window
at `_window_open`, and the eligibility engine is only reached afterwards.

**Which records independently block it**, isolated by extending one window at a
time on throwaway copies and asking the released verifier what it then says:

| probe | released verdict |
|---|---|
| production as it is | `admission-window-not-open`, eligibility `[]` |
| instance window open **only** | `selected-instance-no-longer-eligible`, eligibility **`['advertisement-not-fresh']`** |
| advertisement window open **only** | `admission-window-not-open`, eligibility `[]` |
| both open | **`supported=True`** |

So **two records block it independently**: the instance first, the advertisement
behind it. Neither alone is enough. That is the answer to §B, and it came from
the engine.

## C. The minimum chain — four records, each required by the engine

Renewal is by **successor**, not by extension, and that changes the answer. A new
instance supersedes `CINST-000006`, which the route names as its only candidate
and the selection names as its selected instance — so the question is what the
engine says at each step. Measured, in order:

| # | record | why it is required — the released engine's own words |
|---|---|---|
| 1 | **CADV-000008** | with the instance renewed alone: `selected-instance-no-longer-eligible`, eligibility `['advertisement-not-fresh']` |
| 2 | **CINST-000007** | `admission-window-not-open` is the first reason and **persists** with the advertisement renewed alone |
| 3 | **CROUTE-0007** | with the instance renewed and the route left alone, a `select` **preflight** against the old head resolves `selected_instance_id: null` — it would record a selection that selects nothing |
| 4 | **CSEL-000005** | `claimed-instance-not-selected` for the renewed instance, and it **still** says that after the route is renewed |

**No record kind is renewed without that proof, and none is skipped.** The
supporting records — `CAPDEF-0001`, `CPKG-0001`, `CHOST-0001`, `CCON-0001`,
`TREC-000001`, `TREC-000002` — are untouched: they carry no validity window, the
verifier resolves them through the chain above, and the renewed store passes
`fabric validate` with no findings while they are byte-identical.

Identifiers are **not assumed**: each comes from the released preflight's
`predicted_record_id`, and each sequence advance was measured.

| record | sequence before → after | request digest |
|---|---|---|
| CADV-000008 | advertisement 7 → 8 | `sha256:bbf9abe4…f578` |
| CINST-000007 | instance 6 → 7 | `sha256:e2224ba5…0fee` |
| CROUTE-0007 | route 6 → 7 | `sha256:4b6f3d35…91d2` |
| CSEL-000005 | selection 4 → 5 | `sha256:2215d46f…61c2` |

## D. Nothing is broadened

Asserted field by field against the accepted pre-expiry chain, by the rehearsal
and again by the freeze-artifact suite against the reviewed inputs:

`CAPDEF-0001` · `CPKG-0001` · `CHOST-0001` · `CCON-0001` · contract version
`1.0.0` · `x86-64` · operation `execute` · classification `internal` · target
`HOST-0001` · locality `local-only` · the selection's whole `request_class` ·
the instance's `effective_scope` in all four dimensions · both trust record
references.

No capability, operation, target, classification, contract version, host,
package or locality class is added. `MAXIMUM_SLOTS` is untouched and no execution
runtime object moves.

## E. The new window, and the judgement in it

The old authority closed at `2026-09-23T06:00:00-05:00`. **Nothing is extended
and nothing is rewritten** — these are successors, and the expired records stay
exactly as they are.

| | |
|---|---|
| `observed_at` / advertisement `recorded_at` | **`2026-10-05T15:00:00-05:00`** |
| `valid_until` | **`2026-10-12T06:00:00-05:00`** |
| instance `admitted_at` | `2026-10-05T15:15:00-05:00` |
| instance `admitted_until` | `2026-10-12T06:00:00-05:00` — **equal to the advertisement's close, so it cannot outlive it** |
| route `recorded_at` | `2026-10-05T15:30:00-05:00` |
| selection `recorded_at` / `evaluated_at` | `2026-10-05T15:40:00-05:00` |

**The judgement I want recorded.** The instants are the *preparation* instants —
today, shortly before this report — and the operator will write later. The engine
judges at the instant a request names, never at a clock, so a later write does not
invalidate them. But a `recorded_at` of today, written next week, would claim the
renewal happened earlier than it did, and §E forbids that. So every freeze
artifact carries a **current-time freshness gate** that refuses once
`2026-10-12T06:00:00-05:00` has passed, and says to re-prepare with fresh instants
rather than edit. **If the reviewer authorises the write after that instant, the
chain must be re-prepared — it is designed to refuse, not to be nudged.** If a
tighter honesty standard is wanted, the alternative is to prepare the bodies
without instants and have the operator render them at the moment of writing; I did
not do that because it would move reviewed bytes out of review.

## F. Four freeze artifacts, one record each

`provisioning/fabric/g11-bc-am-{cadv-000008,cinst-000007,croute-0007,csel-000005}-freeze.txt`
with their reviewed inputs beside them. Each one:

1. takes its body from the **reviewed repository file**, not retyped into the
   ceremony — a body retyped into a ceremony is a body nobody reviewed;
2. pins the raw SHA-256 and the byte count;
3. refuses **two** predecessor bodies by name, each a plausible mis-paste sitting
   in `/etc/kyri/fabric` that the Fabric engine would have nothing to say about;
4. gates on the operator's wall clock, reading the instants **out of the rendered
   body** so the gate cannot drift from the bytes it guards, and refuses a window
   that outlives its governing advertisement;
5. pins **its own step's** Fabric baseline;
6. invokes exactly one released verb, with `--preflight`;
7. proves `predicted_record_id`;
8. proves `request_digest` — separately, because `would_accept` alone says a body
   is well formed, not that the engine resolved it to the right record;
9. proves production Fabric byte-identical afterwards;
10. installs exactly one file, into `/etc/kyri/fabric`, and no write path names
    the governed store.

**No production Fabric write is in any artifact.** Each write is a separate
reviewer authorisation and is not written yet — `PRODUCTION_WRITE_ARTIFACTS=NONE`.

**Nothing was frozen into `/etc`.** Preparation is repository-only, as §J prefers.

## G. The chain, as independently reviewable checkpoints

Measured in the scratch rehearsal, with the copy first **proved** to reproduce
production's aggregate once pathnames are rewritten — which is what makes these
numbers ones a ceremony can pin.

| step | PRE_BASELINE | EXPECTED_RECORD | SEQ before → after | POST_BASELINE (rehearsed) |
|---|---|---|---|---|
| 1 | `a87c2010…12e5` | CADV-000008 | advertisement 7 → 8 | `31f49e12…8161` |
| 2 | `31f49e12…8161` | CINST-000007 | instance 6 → 7 | `2c40e705…4612` |
| 3 | `2c40e705…4612` | CROUTE-0007 | route 6 → 7 | `4d814731…ea54` |
| 4 | `4d814731…ea54` | CSEL-000005 | selection 4 → 5 | `304b8e66…7e8c` |

The post-baselines are **rehearsed, not promised**: each is what the released
engine produced on a byte copy, and each remains UNKNOWN for production until the
operator writes. The suite asserts the chain joins — every step's pre-baseline is
the previous step's rehearsed post-baseline.

## H. The scratch rehearsal

`tests/test-fabric-renewal-chain-rehearsal.sh` — **58 PASS, 0 FAIL.** Every
released write names an explicit scratch `--store-root`; production is measured
before and after.

- every released preflight accepts and **mutates nothing**, proved by measuring
  the store across it;
- every predicted identifier matches, and the written `request_digest` is the one
  the preflight predicted;
- every sequence advances by **exactly one**;
- `fabric validate` reports **no findings** against the renewed store;
- the released verifier reports **`supported=True`, `reason=None`,
  `eligibility_reasons=[]`** for `CSEL-000005 → CINST-000007`;
- and the accepted pair **still refuses** — the renewal is append-only and
  rewrote nothing.

### The Stage-3 matrix, against that chain

| | production (expired) | renewed scratch chain |
|---|---|---|
| cases present | 22 / 22 | 22 / 22 |
| fail closed | 22 / 22 | 22 / 22 |
| **reach their intended refusal** | 8 / 22 | **22 / 22** |
| masked | 14 | **0** |
| traceback | 0 | 0 |

## I. What it took, and what it did not

Two honest changes were needed, and they are the kind §I permits:

**BLOCK B's authority pins became substitutable** — selection, instance, route
head and advertisement — exactly as its roots already were. The gates still run
the released verifier at the real clock against a real chain; what an override
changes is *which* chain they are asked about. Production remains the default, and
against production the matrix still reports 8 reached and 14 masked, unchanged.

**The three authority sabotages now derive their target from the chain under
test.** They named `CADV-000007`, `CROUTE-0006` and `CSEL-000004` literally, which
is right while those are the heads and useless the moment they are not: against
the renewed chain two of the three edited a record the gates no longer read, so
BLOCK B passed and the case silently proved nothing. Each now asserts that the
record it is about to break is the one the gates will read.

**What was not done:** BLOCK B is not reordered. No verification is bypassed. No
window is injected into a record. Expired production is not special-cased — it
still reports its 14 masked cases. No intended-refusal requirement became a
generic nonzero-exit assertion. The only reason the fourteen unmask is that the
chain they are asked about is genuinely live.

## K. The escape class, audited

`tests/test-no-production-escape.sh` — **PASS**, across 150 suites. A direct audit
of the three suites this checkpoint touched: 4 CLI dispatches, all with an
explicit `--store-root`, all pointing at a scratch variable; no production store
root in any write position; no `CAPABILITY_RUNTIME_ROOT`; fixture-setup failure
fatal before any executable surface in the one suite that builds and dispatches;
the other two are static and dispatch nothing. **0 failures.**

## And one thing the host told us along the way

The CADM-000001 rehearsal failed in the first validator run, and it was right to.
It was written at G11-BC-AK to assert that an ADR-0016-era record **cannot** be
resumed, because on Generation 22 no call could. Generation 23 is now installed,
so the identical repeat **resumes** — and the suite was asserting a refusal
against a runtime that correctly resumes. Its discriminator asked whether the verb
*requires* the member, which described Generation 22 exactly; it now asks whether
the installed runtime carries `LATER_SCHEMA_MEMBERS` for it, so both branches stay
correct on either host.

It also now asserts the thing that matters most, against the **real accepted
record** rather than a fixture:

```
PASS: the identical correction resumes and reports the record already written
PASS: and it reports no actual_occurrence_at: the legacy record carries none,
      and none was invented
```

**G11-BC-AK obligation 1 is observed resolved on the installed host**, not merely
in the repository.

## L. Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **140/140**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| `run-validation.sh` (full) | **165/165**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| clean clone at `3db9f2a`, full | **165/165**, 0 `FAIL:`, **18 `HOST_ONLY_SKIP`** |
| GitHub CI at `6455293` | CI, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy — **6/6 success** |

The clean clone's 18 skips are all the intentional pinned-checkout refusal, and
every one of them ran for real in the host run, which had **0 skips**. All three
of this checkpoint's suites RAN in the clone with identical results — 58, 66 and
74 — because they need the host's governed stores, not the pinned checkout path.

**CI went red once on `1ea9b31`, and three of the four reds were not mine.**
ShellCheck was a genuine finding — the repository runs it at `info` level and
caught an SC2016 in a grep pattern of my own, since fixed. Semgrep, Trivy and CI
all failed with *"The job was not acquired by Runner of type hosted even after
multiple attempts"*, a GitHub runner-capacity failure. Recorded here rather than
left looking like a code problem; the fixed commit is 6/6.

Fabric plane: runtime **8336** · capability-fabric **538** · freeze-artifacts
**241** · g11-integrity **91** · freeze-gate-execution **75** ·
advertisement-preflight **74** · route-preflight **71** · preflight **67** ·
admission-dependency-bound **44** · instance-admission-integrity **38** ·
route-head **30** · host-admission **27** — all 0 FAIL.

This checkpoint: renewal-chain rehearsal **58** · freeze artifacts **66** ·
Stage-3 gate matrix **74** on production and **94** against the renewed chain ·
no-production-escape **4** — all 0 FAIL. ShellCheck clean on every changed file.

**The two cases are kept apart, as §L requires.** The host suites that ask the
LIVE production verifier still refuse, and are not weakened: that refusal is the
expected current-production expiry. The renewed-authority proof is the scratch
rehearsal, and it proves the matrix fully.

## Questions for the reviewer

1. **The window.** `2026-10-05T15:00:00-05:00` → `2026-10-12T06:00:00-05:00`,
   seven days, with the artifacts refusing after it closes. Accept, or would you
   rather a shorter window and a same-day write?
2. **The authority-pin substitution.** The gate matrix can now be pointed at
   another chain. I believe that is the right shape — it is how the suite already
   handles roots — but it is the one place where a reviewer might want a narrower
   mechanism.
3. **Order after this.** Write the four records one at a time, then re-run the
   matrix against live production and require 22/22 with nothing masked, then the
   §36 audit, then G7?

---

## What was NOT done

No successor was written into production Fabric. Nothing was frozen into `/etc`.
Fabric was not renewed. The execution runtime was not mutated. No capability was
executed. No lifecycle, CADM, CRES or CINV was mutated. No evidence was cleaned.
The §36 audit was not entered. G7 was not entered. Nothing was merged, tagged or
released. ENG-0006 was not begun.
