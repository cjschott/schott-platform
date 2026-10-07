# G11-BC-AP — the admission is re-prepared from the operator's decision instant

**Date:** 2026-10-07
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `d7f7453`
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — CINST-000007 re-derived from the operator's measured admission decision, preflighted against production, and its freeze artifact prepared. **Neither frozen nor written.** No production mutation of any kind.

---

## A. Why the body was re-prepared

An admission is a **decision**. Three instants have now been attached to
`CINST-000007`, and only the third is one:

| instant | what it actually was | status |
|---|---|---|
| `2026-10-06T06:25:30-05:00` | thirty seconds after the advertisement observation — a cadence slot chosen while G11-BC-AM rehearsed the chain whole | rejected at AO |
| `2026-10-06T13:35:00-05:00` | the instant G11-BC-AO was *prepared*. Preparing a body is not deciding to admit it. | **rejected here** |
| `2026-10-07T10:08:58-05:00` | the operator made the admission decision and measured it | **in the reviewed bytes** |

Neither rejected instant survives as a pinned value anywhere in the live
artifact — both appear only in prose explaining why they were replaced, and the
first of them is additionally pinned as a **body to refuse**.

`admitted_until` was deliberately **not** moved. The admission's expiry is
bounded by `CADV-000008`, not by how late the decision was made:

```
CADV-000008   2026-10-06T06:25:00-05:00 -> 2026-10-13T06:25:00-05:00
CINST-000007  2026-10-07T10:08:58-05:00 -> 2026-10-13T06:25:00-05:00
```

Both read out of the records at gate time, not transcribed.

---

## B. The reviewed body

`provisioning/fabric/g11-bc-ap-cinst-000007-input.json`

| value | measured |
|---|---|
| bytes | **1270** |
| body SHA-256 | **`92c71fb26184cc98a55949805cada709b78bd859b0d2b9765f0e85b8b7b09890`** |
| request id | `g11bcap-admit-instance-cpkg-0001-chost-0001-cadv-000008-supersedes-cinst-000006` |
| request digest | **`sha256:06e4cf9676352ebbb950e01702d225cce441b0661e6abc93bdb080953adbd9db`** |
| `admitted_at` = `recorded_at` = `evaluated_at` | `2026-10-07T10:08:58-05:00` |
| `admitted_until` | `2026-10-13T06:25:00-05:00` |

Five fields changed from the superseded AO body and nothing else: the request id,
the three instants, and `provenance.recorded_at` (`2026-10-06` → `2026-10-07`, so
the declaration date is the decision's date). The admission scope, both trust
records, the governing advertisement, the predecessor, the capability, package,
host, contract, version and architecture are **byte-identical** to the AO body,
which was itself field-for-field equal to `CINST-000006`. No authority is
broadened.

### The digest gate is the only thing that stops the superseded body

Both bodies render to **exactly 1270 bytes** — the two instants are the same
width and `g11bcao` and `g11bcap` are the same width. I did not assume a
byte-count gate was insufficient; I measured it. Running gate 5's window check
verbatim against each body, at the real clock:

```
the AP body:  ok  window contained · ok  instants inside · ok  clock inside both   rc=0
the AO body:  ok  window contained · ok  instants inside · ok  clock inside both   rc=0
```

**The superseded AO body passes every window gate.** Its `admitted_at`
`2026-10-06T13:35:00-05:00` is in the past, inside the advertisement's window,
and before an `admitted_until` it does not outlive — it is a structurally valid
admission that the released engine would accept. The preflight would accept it
too. So nothing downstream of gate 4 catches it, and the byte count cannot
either.

What stops it is one line: `SUPERSEDED_AO_BODY=e1bdd53e…dd17`, refused by name at
gate 4. That makes the refusal load-bearing rather than defensive, and the freeze
suite now asserts it as a property — it measures the stale body's length and,
when it equals the live body's, requires the live artifact to pin its digest.

Gate 0's instant assertion is the second line of defence, and it was exercised
for real: supplying no `ADMITTED_AT`, the AO instant, or the AM cadence instant
each refuses before anything is read or written.

---

## C. No G11-BC-AO digest is carried forward

Every number in the live artifact was measured at this checkpoint from its own
source. The audit:

| value | AO | AP | source of the AP value |
|---|---|---|---|
| body SHA | `e1bdd53e…dd17` | **`92c71fb2…9890`** | `sha256sum` of the rendered file |
| request digest | `sha256:7eb452fd…f2b6` | **`sha256:06e4cf96…d9db`** | the released preflight against production |
| persisted record SHA | *(not pinned)* | **`8e577b7d…85ad`** | the scratch write |
| post-write aggregate | `ca6ca223…bafb` | **`1dc83d01…d8cb`** | the scratch write, path-rewritten |
| `ACCEPTED_CINST5` | `850af136…a8da` | `850af136…a8da` | **re-measured** from `/etc/kyri/fabric/cinst-000005.json` |
| `ACCEPTED_CINST6` | `6746234a…e162` | `6746234a…e162` | **re-measured** from `/etc/kyri/fabric/cinst-000006.json` |
| `FABRIC_BEFORE` | `d11c939a…562c` | `d11c939a…562c` | **re-measured** from the live store |

The last three are equal to AO's because they are **facts about production**, not
preparations — and each was read from its own file here rather than copied
across. That distinction is the whole point of the rule: the only AO value
retained by intent is the post-CADV Fabric baseline, and it was re-measured
anyway.

---

## D. The preflight, against production, read-only

```
would_accept          true
mutated               false
destination_exists    false
predicted_record_id   CINST-000007
request_digest        sha256:06e4cf9676352ebbb950e01702d225cce441b0661e6abc93bdb080953adbd9db
```

Production, before and after, unchanged:

| store | aggregate |
|---|---|
| Fabric | `d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c` |
| runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |

| check | result |
|---|---|
| instance sequence | **6**, unmoved |
| `CINST-000007` in production Fabric | **absent** |
| `/etc/kyri/fabric/cinst-000007.json` | **absent** |
| `CINST-000006` | `5a320fa0cb9f678d3f78a11416beec17945b06add25446fbae7e0e1bf5575b9b` — immutable, unsuperseded |
| `CADV-000008` | `8b478c3e8d3ed6c86a63d4dde1901cedfd56d9736b28017cfd384fa78443654c` — the advertisement head at sequence 8 |

The staging directory for the preflight is **not** `/etc` — a `mktemp -d` the
block removes — so nothing was frozen to perform it.

---

## E. The windows, at the real clock

```
now                       2026-10-07T10:18:36-05:00
CADV-000008 observed_at   2026-10-06T06:25:00-05:00   <= now
CADV-000008 valid_until   2026-10-13T06:25:00-05:00   >  now
CINST-000007 admitted_at  2026-10-07T10:08:58-05:00   <= now   (already reached)
CINST-000007 until        2026-10-13T06:25:00-05:00   >  now
```

- `admitted_at >= CADV-000008.observed_at` ✓
- `admitted_until <= CADV-000008.valid_until` ✓ (equal — it ends with its authority)
- `recorded_at`, `evaluated_at` inside `[admitted_at, admitted_until)` ✓

The admission instant is **in the past and already reached**, so the body claims
no decision nobody has made. That was the exact failure at G11-BC-AN, where a
forward-running cadence put `admitted_at` in the future and the released verifier
refused with `admission-window-not-open`.

---

## F. The scratch write, on a byte copy of production

The copy was proved equal to production first (path-rewritten aggregate
`d11c939a…562c`), then the **released** `admit-instance` ran against it:

| check | result |
|---|---|
| outcome | `accepted`, reason `null` |
| record | `CINST-000007` |
| instance sequence | **6 → 7** |
| head by scan | **`CINST-000007`** |
| `advertisement_id` | `CADV-000008` |
| `supersedes` | `CINST-000006` |
| `lifecycle_state` | `admitted` |
| persisted record SHA-256 | `8e577b7df196c80dc380a4e3f62ee98cb60f408b00ec132af50e9da611ce85ad` |
| post-write aggregate (production pathnames) | `1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb` |
| `compute-eligibility` at the real clock | **`eligible: true`**, `reasons: []`, 12/12 conditions met |
| `fabric validate` | `status: reported`, **`findings: []`**, instance count 7 |

These are **comparison values only**. The post-write aggregate is a rehearsed
number and is labelled UNKNOWN-for-production in the artifact until the write
happens.

The chain-rehearsal suite derived the same request digest and the same post-write
aggregate independently, from its own copy — two derivations agreeing.

---

## G. The prepared freeze artifact

`provisioning/fabric/g11-bc-ap-cinst-000007-freeze.txt` — it freezes exactly one
file, `/etc/kyri/fabric/cinst-000007.json`, and contains **no production
`admit-instance` write**. It refuses on:

| refusal | gate |
|---|---|
| no `ADMITTED_AT` supplied | 0 |
| `ADMITTED_AT` not `2026-10-07T10:08:58-05:00` | 0 |
| any of the three production baselines moved | 1 |
| `CADV-000008` not the record written, sequence not 8, or already superseded | 2 |
| instance sequence not 6 | 3 |
| `CINST-000007` already present in production | 3 |
| `CINST-000006` altered or already superseded | 3 |
| `/etc/kyri/fabric/cinst-000007.json` already exists | 4 |
| the body is the **superseded AO body** `e1bdd53e…dd17` | 4 |
| the body is the **AN advertisement body** `f683104575…fcc61` | 4 |
| the body is the `CINST-000005` or `CINST-000006` input | 4 |
| rendered digest or byte count not the reviewed pair | 4 |
| the admission outliving or starting before the advertisement | 5 |
| `recorded_at`/`evaluated_at` outside the admission window | 5 |
| **either window closed at the current clock** | 5 |
| not currently eligible, any eligibility reason, any validate finding, wrong head, wrong sequence, wrong lifecycle on the copy | 6 |
| preflight not accepting, mutating, destination existing, wrong identity, wrong request digest | preflight |
| production Fabric changed, or the instance sequence moved | post-preflight |
| `CINST-000007` reaching production Fabric | post-freeze |

The operator supplies the instant; the artifact never reads a clock to **fill in**
a value. `date`/`now()` appear only in gates that refuse and in the eligibility
call, which must judge at the current instant to mean anything.

`provisioning/fabric/g11-bc-ao-cinst-000007-freeze.txt` is marked **SUPERSEDED AT
G11-BC-AP. DO NOT RUN THIS.** with its old pins intact and its replacement named.
Its input body is kept in the repository as evidence of what AO reviewed.

---

## H. CROUTE-0007 and CSEL-000005

Untouched, still **STALE AFTER G11-BC-AO. DO NOT RUN THIS.** Their instants sit
at `2026-10-06T06:26`, now a full day before the admission, so a selection
evaluated there resolves to no instance — the released engine says
`selection-recorded-no-instance`. Each is re-prepared at its own checkpoint from
its own rehearsal. The chain-rehearsal suite does not rehearse them and says why.

---

## I. Suites

| suite | result |
|---|---|
| `tests/test-fabric-renewal-freeze-artifacts.sh` | **84 PASS / 0 FAIL** (was 78) |
| `tests/test-fabric-renewal-chain-rehearsal.sh` | **19 PASS / 0 FAIL** |

Three checks were added to the freeze suite, and one repaired:

1. **The supersession chain must resolve.** The admission's chain is now two hops
   (AM → AO → AP). A superseded artifact may name another superseded one, but
   following the pointers forward must terminate at the artifact the suite calls
   live. Without this, AM's pointer at the now-superseded AO artifact would have
   passed silently and a reader following the chain would dead-end on a
   DO-NOT-RUN file.
2. **A superseded body of equal length must be refused by digest.** Asserted as a
   property: the suite measures the stale body, and *if* it is the same length as
   the live one, the live artifact must pin its digest.
3. **The scope check now reads the body that will be written.** It was still
   loading `g11-bc-am-cinst-000007-input.json` — a pre-existing gap I introduced
   at AO when the ARTIFACTS row moved to the AO body and this block did not. The
   AM scope happens to be identical, so the check passed while verifying a body
   nobody will ever write.

---

## J. Validation

| run | result |
|---|---|
| `tools/dev/run-validation.sh` (full) | **165/165**, 0 FAIL, 0 FAILED, **0 host-only skips** |
| `tools/dev/run-validation.sh --quick` | **140/140**, 0 FAIL, 0 FAILED, 0 skips |
| clean clone of `8502079` at `/data/kyri` | **165/165**, 0 FAIL, **18 host-only skips** |
| GitHub CI on `8502079` | **6/6 green** — Static validation, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy |

All 18 clean-clone skips are the same reason — `checkout … is not the pinned
/opt/schott-platform` — for the ceremony and generation-installer suites that
drive the real checkout. Same count as G11-BC-AO. The two Fabric suites ran in
the clone, at steps 103 and 104.

`TOTAL_STEPS` needed no change: no suite was added, only re-pinned.

The two Fabric suites inside the full run: step 103 `Fabric renewal chain
rehearsal passed (prepared steps only)`, step 104 `Fabric renewal
freeze-artifact validation passed`.

---

## K. Production state at the close of this checkpoint

| store | aggregate | moved? |
|---|---|---|
| `/var/lib/kyri/fabric` | `d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c` | no |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | no |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | no |

`CINST-000007` is absent from production Fabric and absent from
`/etc/kyri/fabric`. Advertisement sequence 8, instance sequence 6. Nothing was
frozen, written, installed or renewed at this checkpoint.

---

## L. What this checkpoint did not do

Not frozen, not written, not begun: the `admit-instance` production write;
`CROUTE-0007`; `CSEL-000005`; any capability execution; the §36 audit; G7;
ENG-0006. The Stage-3 gate matrix still has **14 of 22 cases masked**, and it
stays masked until a selection resolves to an admitted instance — which needs
`CSEL-000005`, two authorisations away.

---

## M. Questions for the reviewer

1. **The admission instant is now an operator-asserted gate, and the reviewed
   bytes are the only place it lives.** Gate 0 refuses unless the operator types
   `ADMITTED_AT=2026-10-07T10:08:58-05:00`. If the decision is re-made later, the
   body is re-prepared again rather than edited — which is the third
   re-preparation of this record. Is that the cadence you want, or should the
   admission be frozen only in the same sitting as the write, so a decision
   cannot age out of its own preparation?
2. **`admitted_until` is unchanged across all three preparations.** The admission
   now has a 6-day window instead of 7, because the decision came a day after
   the advertisement observation and the expiry is bounded by `CADV-000008`. I
   read "the admission must not outlive CADV-000008" as the binding constraint
   and left the expiry alone. Confirm that, rather than a fresh 7 days that would
   have to be clipped anyway.
3. **The scope check in the freeze suite was verifying the wrong body since
   G11-BC-AO** — it still loaded the AM admission input after the ARTIFACTS row
   moved. The AM and AP scopes are identical, so the check passed while proving
   nothing about the live body. Fixed here. Worth asking whether other suites
   pin a body by one path and check it by another.
