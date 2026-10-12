# G11-BC-AS — CROUTE-0007 verified; CSEL-000005 prepared, and the chain closes on the scratch proof

**Date:** 2026-10-08
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `fc151fc`
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — `CROUTE-0007` verified by content with mutation accounting PASS. `CSEL-000005` rendered from the operator's measured selection decision, preflighted, rehearsed, and its freeze artifact prepared. **Neither frozen nor written.** No production mutation.

---

## A. CROUTE-0007, verified by content

The production write matches the G11-BC-AR rehearsal **exactly** — record and
whole store:

| | measured | expected |
|---|---|---|
| persisted record | `3ab79b33558f411d76d62d1dd48dbc2c89a51420ea73caa4032698a970bb7c24` | identical to the AR rehearsal ✓ |
| Fabric aggregate | `758c6c6578abdfccc7d29d2f1b7e9d56cbf4d933636853c884fb599ef70862ba` | identical to the AR rehearsal ✓ |
| runtime / Trust | `7dfb34e6…2e99` / `53605e4e…b63f` | unmoved ✓ |

**All 16 semantic checks pass** against the reviewed AR input: `route_id`,
`route_version` 7, `supersedes`, `capability_id`, `contract_id`,
`data_classification`, `locality`, `kind`, `schema_version`,
`candidate_instances` `[CINST-000007]`, `accepted_contract_versions` `[1.0.0]`,
and five `evidence` members including the request digest
`sha256:db8962e3…2e9e` and `recorded_at 2026-10-07T17:36:09-05:00`.

Sequences: advertisement 8, instance 7, route **7**, selection 4. Heads by scan:
`CADV-000008`, `CINST-000007`, **`CROUTE-0007`**. `CROUTE-0006` byte-identical at
`ffa04e0f…f3f2` and now superseded by `CROUTE-0007`. `fabric validate`:
**`findings: []`**.

### Mutation accounting: PASS

Remove `CROUTE-0007`, rewind the route sequence 7 → 6:

```
rewound:           1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb
expected pre-route 1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb
```

Exactly two files moved: `+ capability-routes/CROUTE-0007.yaml` and the route
sequence file.

---

## B. The selection decision instant

The operator supplied `2026-10-08T03:32:26-05:00`. Measured against the clock
before rendering anything:

```
now                        2026-10-08T03:34:10-05:00
selection decision         2026-10-08T03:32:26-05:00   reached, 105 seconds in the past
```

| bound | holds |
|---|---|
| `CROUTE-0007 recorded_at 2026-10-07T17:36:09-05:00 <= selection instant` | ✓ |
| `CINST-000007 admitted_at 2026-10-07T10:08:58-05:00 <= selection instant` | ✓ |
| `selection instant < CINST-000007 admitted_until 2026-10-13T06:25:00-05:00` | ✓ |
| `selection instant < CADV-000008 valid_until 2026-10-13T06:25:00-05:00` | ✓ |
| clock inside both governing windows | ✓ |

---

## C. `selected_at` is derived, not supplied — a deviation from the brief's wording

The brief said to set `recorded_at = selected_at = 2026-10-08T03:32:26-05:00`.
**`selected_at` is not an input member.** The released engine sets it when it
writes the record (`tools/fabric/selection.py`: `selected_at=recorded_at`), and
`tools/fabric/cli.py` splats the body as keyword arguments into
`select_candidate(...)`, so an unknown member raises `TypeError` and the CLI
refuses with *"the decision body does not match this operation"*.

I did not infer that from reading — I tried it:

```
body carrying selected_at  ->  fabric: the decision body does not match this operation
```

So the body carries `recorded_at` and `evaluated_at`, both the operator's
instant, and the engine derives `selected_at` from `recorded_at`. The brief's
intent is satisfied exactly — the written record carries
`selected_at: '2026-10-08T03:32:26-05:00'` — but **by construction rather than by
supplying it**, and supplying it would have made the ceremony fail at the
keyboard. Gate 4 of the artifact now refuses a body that carries `selected_at`,
with that explanation, so the next person does not learn it from a cryptic
refusal.

On `evaluated_at`: it has a distinct *meaning* — it is the instant eligibility is
judged at — but not a distinct value here. The operator's decision is both when
they decided and the instant the decision was evaluated at, and the accepted
`CSEL-000004` used one value for both.

---

## D. What the engine enforces, measured — the answer the brief asked for

Eight instant pairs against a copy of production:

| `recorded_at` / `evaluated_at` | `would_accept` | resolves to |
|---|---|---|
| the reviewed instant | **true** | `CINST-000007` |
| 1s **before the route** it resolves through | **true** | **`CINST-000007`** |
| after admission, 7h **before the route** | **true** | **`CINST-000007`** |
| before the admission (both fields) | **true** | `None` |
| recorded ok, `evaluated_at` pre-admission | **true** | `None` |
| after both windows close | **true** | `None` |
| recorded ok, `evaluated_at` post-expiry | **true** | `None` |
| **`recorded_at` in December**, evaluated ok | **true** | **`CINST-000007`** |

Precisely:

- **`evaluated_at` is the only field that moves the answer.** Outside the
  admission window the selection resolves to `null`.
- **The engine never refuses.** `would_accept: true` in all eight. A null
  resolution is *reported*, not rejected — the engine will persist an accepted
  selection that selects nothing.
- **`recorded_at` has no effect on resolution at all.** A selection dated a day
  before the route it resolves through, or dated in December, still resolves to
  `CINST-000007`.

**Engine authority:** eligibility at `evaluated_at`, expressed only as a null
resolution.
**Ceremony authority:** `recorded_at >= CROUTE-0007.recorded_at`; neither instant
in the future; neither at or after either expiry; and — the important one —
**`selected_instance_id == CINST-000007`, not `would_accept`.**

---

## E. The reviewed body

`provisioning/fabric/g11-bc-as-csel-000005-input.json`

| value | measured |
|---|---|
| bytes | **606** |
| body SHA-256 | **`4a98b76bf1131788cf19b2728ee5e854f99cc2e3eaabe0580b9799de83838231`** |
| request id | `g11bcas-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0007` |
| request digest | **`sha256:dd232d5275cd5a69959772179668f9964f8a455bc748199442e7b2570817d721`** |
| `recorded_at` = `evaluated_at` | `2026-10-08T03:32:26-05:00` |

Three fields differ from the stale AM body: the request id, the two instants, and
`provenance.recorded_at`. Request class equal to `CSEL-000004` field by field:
`CAPDEF-0001`, `CCON-0001`, `[1.0.0]`, `internal`, `local-only`, node
`HOST-0001`. No authority broadened.

**The stale AM body is also 606 bytes** — the third same-length collision in this
chain, after the admission's 1270 and the route's 679. Refused by digest.

### Digest coverage, confirmed for a selection too

| change | request digest |
|---|---|
| none | `sha256:dd232d52…d721` |
| `request_id` only | `sha256:dd232d52…d721` — **unchanged** |
| `actor` only | `sha256:672bdc19…f785` |
| `local_node_identity` only | `sha256:ab8f8518…d071` |

So the AQ finding holds for `select`: the digest does not cover `request_id`. The
artifact pins the body SHA, the byte count, the request digest, **and** reads
`request_id`, `recorded_at` and `evaluated_at` out of the body directly.

---

## F. Preflight against production, read-only

```
would_accept          true
mutated               false
destination_exists    false
predicted_record_id   CSEL-000005
selected_instance_id  CINST-000007
request_digest        sha256:dd232d5275cd5a69959772179668f9964f8a455bc748199442e7b2570817d721
```

Fabric `758c6c65…62ba` before and after; selection sequence **4**, unmoved;
`CSEL-000005` absent from production and from `/etc`; `CSEL-000004` immutable at
`5e58396f3e6937701f07c8b7f2aabbfdb7483213f801358e5ea369eb223aaf24`.

**Selections carry no `supersedes` field at all** — I checked all four, and every
one has zero. So there is no supersession head to verify for a selection, and the
artifact does not pretend otherwise: it gates on the sequence being 4, on
`CSEL-000005` being absent, and on `CSEL-000004`'s bytes. It also refuses if a
selection record ever *starts* carrying `supersedes`, because that would
invalidate the reasoning rather than silently pass.

---

## G. The scratch write

| check | result |
|---|---|
| outcome | `accepted`, reason `null` |
| selection sequence | **4 → 5** |
| `route_id` / `route_version` | **`CROUTE-0007`** / **7** |
| `selected_instance_id` | **`CINST-000007`** |
| `considered_candidates` | **`[CINST-000007]`** |
| `excluded_candidates` | **`[]`** |
| derived `selected_at` | **`2026-10-08T03:32:26-05:00`** |
| `selection_reason` | `first eligible candidate in declared order` |
| `fabric validate` | `findings: []`, selections 5 |
| persisted record SHA-256 | `bc464efcee8c70b0a17678e3011a204f677f2ffb08f5afee16a4e52d8c2510f0` |
| post-write aggregate | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |

### Current execution authority, restored

The released `verify_selected_evidence`, at the real clock:

```
scratch renewed chain  (CSEL-000005 -> CINST-000007):  supported=True  reason=None  eligibility_reasons=[]
production as it stands (CSEL-000004 -> CINST-000006):  supported=False reason=admission-window-not-open
```

Comparison values only. The chain-rehearsal suite derived the same post-write
aggregate independently and reported the same verdict.

---

## H. The Stage-3 matrix closes — on the scratch chain

Against the scratch renewed chain:

| tally | value |
|---|---|
| present | **22 / 22** |
| fail_closed | **22 / 22** |
| intended_refusal | **22 / 22** |
| masked | **0** |
| tracebacks | **0** |
| PASS / FAIL | 94 / 0 |

Against **production as it stands**, the same matrix is still **8 reached / 14
masked** (74 PASS / 0 FAIL). That contrast is the point: **O3 is proved
achievable, not closed.** It closes when `CSEL-000005` is actually written and
the matrix is re-run against live production.

One correction to my own first tally: I initially counted "traceback 22" from a
grep that matched the 22 `PASS: …: no traceback` *assertions*. Actual Python
tracebacks in the run: **0**.

---

## I. The prepared freeze artifact

`provisioning/fabric/g11-bc-as-csel-000005-freeze.txt` — freezes exactly
`/etc/kyri/fabric/csel-000005.json`, contains **no production `select`**, and
refuses on:

| refusal | gate |
|---|---|
| missing `SELECTION_DECISION_AT`, or any value other than `2026-10-08T03:32:26-05:00` | 0 |
| any of the three production baselines moved | 1 |
| `CADV-000008`, `CINST-000007` or `CROUTE-0007` not the written record | 2 |
| any of the three superseded, or the admission not `admitted` | 2 |
| advertisement/instance/route sequence not 8/7/7 | 2 |
| `CROUTE-0007` not offering `CINST-000007` | 2 |
| selection sequence not 4; `CSEL-000005` present; `CSEL-000004` altered | 3 |
| a selection record acquiring a `supersedes` field | 3 |
| the body is the **stale AM selection body**, or the `CSEL-000003`/`CSEL-000004` input | 4 |
| rendered digest, byte count, `request_id`, `recorded_at` or `evaluated_at` wrong | 4 |
| the body carries **`selected_at`**, which the engine would refuse cryptically | 4 |
| selection instant before `CROUTE-0007`'s own `recorded_at` | 5 |
| either instant before the admission, at/after its expiry, at/after the advertisement's expiry, or **in the future** | 5 |
| either governing window closed at the current clock | 5 |
| **`selected_instance_id` null, or not `CINST-000007`** | 6 |
| preflight not accepting, mutating, destination existing, wrong identity/digest/request id | 6 |
| production Fabric changed, or the selection sequence moved | post-preflight |
| wrong route, version, candidates, exclusions, derived `selected_at`, sequence, or any finding on the copy | 7 |
| `verify_selected_evidence` not answering `supported=True reason=None` with no eligibility reasons | 7 |
| `CSEL-000005` reaching production Fabric | post-freeze |

Gates 0 and 5 were exercised for real: missing and stale instants refuse, and
gate 5 refuses the stale AM body, an instant one second before the route, one
seven hours before it, one exactly at expiry, and one dated tomorrow — every case
the engine accepts.

`provisioning/fabric/g11-bc-am-csel-000005-freeze.txt` is marked **SUPERSEDED AT
G11-BC-AS. DO NOT RUN THIS.** with its old pins intact.

---

## J. Suite changes

| suite | before | after |
|---|---|---|
| `test-fabric-renewal-chain-rehearsal.sh` | 23 PASS / 0 FAIL | **42 PASS / 0 FAIL** |
| `test-fabric-renewal-freeze-artifacts.sh` | 87 PASS / 0 FAIL | **90 PASS / 0 FAIL** |

The chain rehearsal ran its **completion path for the first time**, written back
at G11-BC-AM and gated on all four steps being prepared. It independently
confirms the final baseline, the `supported=True` verdict, that the accepted pair
*still refuses* (so the renewal rewrote nothing), no findings, no authority
broadened across all four records, and the 22/22 matrix with no masking and no
traceback.

One suite check was generalised rather than extended: the superseded-banner
regex enumerated checkpoint letters (`G11-BC-A[NOPR]`), so every re-derivation
required editing it, and forgetting the edit is exactly how a live artifact and a
superseded one become indistinguishable. It now matches the banner's *shape*.

### And the recurring cost of the accepted-baseline discipline

The full validator failed first time, at step 94:

```
FAIL: production Fabric is 758c6c65…62ba, which is no baseline this repository accounts for
FAILED: CINV-000003 Stage 0 rehearsal (exit 1)
```

That is the discipline working, not a defect: the two spent-mode stage rehearsals
pin a *named* set of accepted Fabric baselines rather than "whatever is there", so
every renewal write needs one reviewed line. Both now name
`758c6c65…62ba` as the post-`CROUTE-0007` state. This is the second time in three
checkpoints (G11-BC-AQ was the first, for the admission write).

**The same will happen when `CSEL-000005` is written.** The post-write aggregate
will be `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b`, and
until a reviewed line names it, `test-capability-cinv-000003-stage-0-rehearsal.sh`
and `…-stage-1-rehearsal.sh` will both fail for that one reason. I have
deliberately **not** pre-added it: a line accepting a store that does not exist
yet is "whatever exists" by anticipation, which is the thing the named set exists
to prevent. The freeze artifact's trailing note warns the operator so a red
validator after the write is not read as a defect.

---

## K. Production state at the close

| store | aggregate | moved? |
|---|---|---|
| `/var/lib/kyri/fabric` | `758c6c6578abdfccc7d29d2f1b7e9d56cbf4d933636853c884fb599ef70862ba` | no |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | no |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | no |

Re-measured after every probe and rehearsal. Selection sequence 4,
`CSEL-000005` absent from the store and from `/etc`. No capability executed:
`CRES-000002` byte-identical, no `CRES-000003`.

---

## L. What this checkpoint did not do

Nothing frozen into `/etc`; no production `select`; no capability executed; no
runtime, lifecycle or administrative-evidence mutation; nothing else renewed or
extended; §36 and G7 not entered; nothing merged, tagged or released; ENG-0006
not begun.

---

## M. Validation

| run | result |
|---|---|
| `tools/dev/run-validation.sh` (full) | **165/165**, 0 FAIL, 0 FAILED, **0 host-only skips** |
| clean clone of `c089a84` | **165/165**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `c089a84` | **6/6 green** — Static validation, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy |

The first full run failed at step 94 on the unaccounted post-route baseline, as
§J records; it passed after the two reviewed lines were added. The clean clone
ran the chain rehearsal's completion path too, reporting `22 reached their own
refusal, 0 masked` against the renewed chain.

`TOTAL_STEPS` needed no change: no suite was added.

---

## N. Questions for the reviewer

1. **`selected_at` could not be supplied as the brief specified.** It is derived,
   and a body carrying it makes the engine refuse outright. I rendered the body
   without it and let the engine derive the operator's instant, which produces
   exactly the record the brief describes. Confirm that reading rather than my
   having under-delivered the instruction.
2. **`select` never refuses, for anything temporal.** Eight probes, `would_accept:
   true` in all eight, including a selection dated in December. The protection is
   entirely in the ceremony — `selected_instance_id == CINST-000007`, never
   `would_accept`. Combined with the AQ/AR finding that `create-route` enforces no
   ordering either, two of the four renewal verbs now rely wholly on artifact
   text. That is the third checkpoint raising this; it may deserve an ADR and an
   engine change rather than another artifact that happens to be careful.
3. **O3 is proved on scratch, not closed in production.** The matrix goes 8/14 →
   22/0 the moment `CSEL-000005` exists. I have deliberately not claimed closure.
   The write is one authorisation away, and the re-run against live production is
   what closes it.
