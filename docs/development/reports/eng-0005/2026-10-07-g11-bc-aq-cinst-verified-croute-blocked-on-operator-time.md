# G11-BC-AQ — CINST-000007 verified; CROUTE-0007 blocked on the operator's decision instant

**Date:** 2026-10-07
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `d805713`
**Engineer:** Claude (implementation)
**Status:** OPERATOR_TIME_REQUIRED — `CINST-000007` verified by content with mutation accounting PASS. `CROUTE-0007` cannot be rendered: its only decision timestamp is the operator's and it has not been supplied. Nothing frozen, nothing written.

---

## A. CINST-000007, verified by content

The production write matches the G11-BC-AP rehearsal **exactly** — not just the
record, but the whole store:

| | measured | expected |
|---|---|---|
| persisted record | `8e577b7df196c80dc380a4e3f62ee98cb60f408b00ec132af50e9da611ce85ad` | identical to the AP rehearsal ✓ |
| Fabric aggregate | `1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb` | identical to the AP rehearsal ✓ |
| runtime | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | unmoved ✓ |
| Trust | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | unmoved ✓ |

Sequences: advertisement 8, instance **7**, route 6, selection 4. Record counts
match each sequence. Heads by scan: `CADV-000008`, **`CINST-000007`**,
`CROUTE-0006`.

**All 22 semantic checks pass**, field by field against the reviewed AP input:
`instance_id`, `advertisement_id`, `supersedes`, `capability_id`,
`capability_package_id`, `capability_host_id`, `contract_id`, both trust records,
`admitted_at`, `admitted_until`, `lifecycle_state: admitted`, `schema_version`,
`evidence.request_digest`, `evidence.request_id`, `evidence.recorded_at`,
`evidence.actor`, `evidence.approving_authority`, and all four scope dimensions.

`CINST-000006` is byte-identical at `5a320fa0…5b9b` — the supersession is
recorded *inside* `CINST-000007`, not by editing its predecessor.

`fabric validate` against production: `status: reported`, **`findings: []`**.

Current eligibility, released engine at the real clock: **`eligible: true`,
`reasons: []`, 12/12 conditions met.**

### Mutation accounting: PASS

On a copy: remove `CINST-000007`, rewind the instance sequence 7 → 6:

```
rewound:            d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c
expected pre-CINST: d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c
```

Reproduced exactly. The file-level diff confirms the mutation was **exactly two
files**: `+ capability-instances/CINST-000007.yaml` and the instance sequence
file. Nothing else in the store moved.

---

## B. Why CROUTE-0007 cannot be rendered yet

The route input carries **exactly one** decision timestamp: `recorded_at` (plus
`provenance.recorded_at`, its date). There is no `evaluated_at` and no separate
`decided_at`. Every value the freeze artifact must pin derives from it — body
SHA-256, byte count, request digest, persisted record SHA, post-write aggregate.

A route is a **decision**, and this checkpoint has no decision instant to render
from. Inventing one would repeat precisely the error that cost G11-BC-AM and
G11-BC-AO their CINST bodies: AM used a cadence slot, AO used its own preparation
time, and both had to be thrown away. So no bytes were rendered.

**`RESULT=OPERATOR_TIME_REQUIRED`.** The operator runs:

```
date -Is
```

at the moment the route decision is made, and supplies that instant. It must fall
inside:

```
2026-10-07T10:08:58-05:00   (CINST-000007 admitted_at -- the route cannot precede its candidate)
    <= route recorded_at <
2026-10-13T06:25:00-05:00   (CADV-000008 / CINST-000007 expiry)
```

and must already be reached at freeze time.

### The field set, settled now so rendering is mechanical

Everything except the instant is derived from production and fixed:

| field | value | source |
|---|---|---|
| `route_id` | `CROUTE-0007` | next sequence |
| `supersedes` | `CROUTE-0006` | current route head |
| `route_version` | `7` | predecessor's 6 + 1 |
| `capability_id` | `CAPDEF-0001` | equal to `CROUTE-0006` |
| `contract_id` | `CCON-0001` | equal to `CROUTE-0006` |
| `accepted_contract_versions` | `["1.0.0"]` | equal to `CROUTE-0006` |
| `data_classification` | `internal` | equal to `CROUTE-0006` |
| `locality` | `local-only` | equal to `CROUTE-0006` |
| `candidate_instances` | `["CINST-000007"]` | **the only semantic change** |
| `actor` / `approving_authority` | `primary-platform-operator` | equal to `CROUTE-0006` |

No authority expansion: the route moves its candidate from the superseded
`CINST-000006` to the admitted `CINST-000007` and changes nothing else.

---

## C. The route successor is necessary, and sufficient — both proved

Against throwaway copies of production, with the released engine.

**Necessary.** With the current route head `CROUTE-0006`, whose
`candidate_instances` is the now-superseded `CINST-000006`, a selection preflight
returns:

```
selected_instance_id: null
would_accept:         true
```

`would_accept: true` is the part that matters: **the engine would happily write a
selection that selects nothing.** Leaving the route alone does not fail loudly —
it produces an accepted record with no instance behind it.

**Sufficient.** After a scratch `create-route` carrying `CINST-000007`:

| check | result |
|---|---|
| `create-route` preflight | `would_accept true`, `mutated false`, `destination_exists false`, `CROUTE-0007` |
| write outcome | `accepted`, reason `null` |
| route head by scan | **`CROUTE-0007`** |
| route sequence | 6 → **7** |
| `route_version` | **7** |
| `candidate_instances` | **`[CINST-000007]`** |
| `locality` / `data_classification` | `local-only` / `internal` — unchanged |
| `CROUTE-0006` | `ffa04e0f…f3f2` — byte-identical, immutable |
| `fabric validate` | `findings: []`, routes 7 |
| **selection preflight through the new head** | **`selected_instance_id: CINST-000007`** |
| `CINST-000007` eligibility | `true`, `reasons: []` |

The instant used for that rehearsal was a throwaway labelled REHEARSAL-ONLY in
the run, and **every digest it produced is discarded.** None appears in this
report as a pin, and none will be carried into the artifact.

---

## D. Two findings about the engine

### 1. `create-route` does not constrain `recorded_at` at all

I probed the released `create-route` preflight with five distinct bodies, each
differing only in `recorded_at`, confirming the bodies really differed by their
request digests:

| `recorded_at` | result |
|---|---|
| `2026-10-07T10:08:57-05:00` (one second before the admission) | `would_accept: true` |
| `2026-10-06T06:26:00-05:00` (the stale AM instant, a day early) | `would_accept: true` |
| `2026-10-07T10:08:58-05:00` (exactly at the admission) | `would_accept: true` |
| now | `would_accept: true` |
| `2026-10-20T00:00:00-05:00` (**after both windows close**) | `would_accept: true` |

So the engine will accept a route recorded before its own candidate was admitted,
or after the governing authority has expired. **The ordering is not enforced by
the engine — it has to be enforced by the freeze artifact's gates.** That makes
the route artifact's window gate load-bearing in the same way the AP admission
artifact's digest refusal turned out to be.

*(First attempt at this probe was wrong: `chmod 0400` left the staging file
unwritable, so four of five rounds silently re-tested the first body. Redone with
the bytes proved distinct each round.)*

### 2. The request digest does not cover `request_id`

Rendering the stale AM route body unmodified reproduces its pinned digest exactly
— `sha256:093bb3834553cac3dd7cd0d6d1de566f8753e124fa8a9b5cdc2f664fa6056279` —
which confirms both that the body is intact and that the harness is faithful.
Then, changing **only** `request_id`:

| change | request digest |
|---|---|
| none | `sha256:093bb38345…56279` |
| `request_id` only | `sha256:093bb38345…56279` — **unchanged** |
| `actor` only | `sha256:b68502e68b…96b5` |
| `recorded_at` only | `sha256:690e05fc5a…1142` |

`request_id` is recorded in `evidence.request_id` but is **not bound by the
request digest**. Two submissions with identical decision content and different
request ids are digest-indistinguishable. The freeze artifacts are unaffected
because they pin the body SHA-256, which does cover it — but an artifact that
pinned only the request digest would not pin which request produced the record.

---

## E. Production state at the close

| store | aggregate | moved? |
|---|---|---|
| `/var/lib/kyri/fabric` | `1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb` | no |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | no |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | no |

Re-measured after every scratch rehearsal. `CROUTE-0007` is absent from
production and from `/etc/kyri/fabric`. Route sequence 6, selection sequence 4.

---

## F. What this checkpoint did not do

No `CROUTE-0007` body rendered, no artifact prepared, nothing frozen into `/etc`,
no production `create-route`. `CSEL-000005` untouched and still STALE — its body
and instant are derived only after `CROUTE-0007` is written and accepted. No
capability execution, no runtime mutation, §36 and G7 not entered, ENG-0006 not
begun.

The Stage-3 gate matrix remains **8 reached / 14 masked**. It needs a selection
resolving to an admitted instance, which is now two authorisations away:
`CROUTE-0007`, then `CSEL-000005`.

---

## G. Validation

| run | result |
|---|---|
| `tools/dev/run-validation.sh` (full) | **165/165**, 0 FAIL, 0 FAILED, **0 host-only skips** |
| clean clone of `5599d8b` | **165/165**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `5599d8b` | **6/6 green** — Static validation, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy |

Suite-level, after the write moved production:

| suite | before | after |
|---|---|---|
| `test-capability-cinv-000003-stage-0-rehearsal.sh` | 14 PASS / **1 FAIL** | **15 PASS / 0 FAIL** |
| `test-capability-cinv-000003-stage-1-rehearsal.sh` | 25 PASS / **1 FAIL** | **26 PASS / 0 FAIL** |
| `test-fabric-renewal-chain-rehearsal.sh` | 19 PASS / 0 FAIL | **12 PASS / 0 FAIL** |
| `test-fabric-renewal-freeze-artifacts.sh` | 84 PASS / 0 FAIL | **84 PASS / 0 FAIL** |
| `test-capability-cinv-000003-stage-3-gate-matrix.sh` | 74 PASS / 0 FAIL | **74 PASS / 0 FAIL** |

The two stage rehearsals failed *correctly* before the edit: each pins a named
set of accepted Fabric baselines rather than "whatever is there", so a renewal
that lands later is a reviewable one-line addition and an unaccounted store is a
refusal. Each now names `1dc83d01…d8cb`.

The chain rehearsal fell from 19 to 12 assertions with no edit at all: the
`CINST-000007` step crossed from *rehearsing* to *verifying*, because the
written-step branch built at G11-BC-AO detects the record in production and
checks the write instead of replaying it. Three verification assertions replace
eight rehearsal ones.

---

## H. Questions for the reviewer

1. **The route decision instant is required before any bytes exist.** I stopped
   rather than render, per the brief. Confirm the sequence: operator supplies
   `date -Is` → I render, measure and pin → reviewer verifies → operator freezes
   → operator writes. That is four exchanges for one record; if you want it
   shorter, the alternative is rendering at the freeze keyboard, which G11-BC-AN
   explicitly forbade.
2. **`create-route` accepts an expired or pre-admission `recorded_at`.** Should
   the gate live only in the artifact, as it does now, or is this a defect in the
   released engine worth an ADR? A route recorded after its authority expired is
   not a representable decision, and the engine currently writes it.
3. **`request_id` is outside the request digest.** Deliberate — the digest
   identifies the decision, not the submission — or an integrity gap? It matters
   for any future gate that pins a request digest without the body SHA.
