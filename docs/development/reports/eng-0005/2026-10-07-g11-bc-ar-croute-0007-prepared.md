# G11-BC-AR — CROUTE-0007 rendered from the operator's route decision and prepared

**Date:** 2026-10-07
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `440edfd`
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — `CROUTE-0007` rendered from the operator's measured route decision, preflighted, rehearsed, and its freeze artifact prepared. **Neither frozen nor written.** No production mutation.

---

## A. The decision instant, checked against the clock first

The operator supplied `2026-10-07T17:36:09-05:00`. Before rendering anything I
measured the clock, because an instant that has not arrived is the exact failure
that cost G11-BC-AN its chain:

```
now                        2026-10-07T17:37:30-05:00
route decision             2026-10-07T17:36:09-05:00   reached, 82 seconds in the past
```

| bound | holds |
|---|---|
| `CINST-000007 admitted_at 2026-10-07T10:08:58-05:00 <= recorded_at` | ✓ |
| `recorded_at < CINST-000007 admitted_until 2026-10-13T06:25:00-05:00` | ✓ |
| `recorded_at < CADV-000008 valid_until 2026-10-13T06:25:00-05:00` | ✓ |
| `recorded_at <= now` | ✓ |

---

## B. The reviewed body

`provisioning/fabric/g11-bc-ar-croute-0007-input.json`

| value | measured |
|---|---|
| bytes | **679** |
| body SHA-256 | **`beb687c26677cad701519b635b7b1ee82bb8721f4da10d0f7d1a9c29b5ca2989`** |
| request id | `g11bcar-create-route-capdef-0001-ccon-0001-cinst-000007-supersedes-croute-0006` |
| request digest | **`sha256:db8962e39dcb6efb2b1a91c12ca7b97f8d2ae446e8225f226b4228144cba2e9e`** |
| `recorded_at` | `2026-10-07T17:36:09-05:00` |

Three fields differ from the stale G11-BC-AM body and nothing else: the request
id, `recorded_at`, and `provenance.recorded_at` (`2026-10-06` → `2026-10-07`).

Against `CROUTE-0006`, field by field: `capability_id`, `contract_id`,
`accepted_contract_versions`, `data_classification` and `locality` are all equal;
`route_version` goes 6 → 7; `candidate_instances` goes `[CINST-000006]` →
`[CINST-000007]`. **That candidate is the only semantic change.** No authority is
broadened.

### The same 679-byte collision as the admission

The stale AM route body is also **679 bytes** — the two instants are the same
width and `g11bcan` and `g11bcar` are the same width. A byte count cannot tell
them apart, so the artifact refuses the stale body **by digest**, and the freeze
suite asserts that as a property.

---

## C. The temporal gate is ceremony authority, and it is load-bearing

G11-BC-AQ found that `create-route` does not constrain `recorded_at`. I did not
take that on trust at this checkpoint — I exercised **every bound in the gate
independently**, and confirmed the engine's answer for each:

| `recorded_at` | the engine | gate 5 |
|---|---|---|
| `2026-10-06T06:26:00-05:00` — the stale AM body, a day before the admission | `would_accept: true` | **REFUSE** — before its candidate was admitted |
| `2026-10-07T10:08:57-05:00` — one second before the admission | `would_accept: true` | **REFUSE** — same bound, at the boundary |
| `2026-10-13T06:25:00-05:00` — exactly at expiry | — | **REFUSE** — at or after the admission expires |
| `2026-10-20T00:00:00-05:00` — after both windows close | `would_accept: true` | **REFUSE** |
| `2026-10-08T12:00:00-05:00` — **in the future, but inside both windows** | `would_accept: true` | **REFUSE** — claims a decision nobody has made |
| `2026-10-12T23:00:00-05:00` — future, late in the window | — | **REFUSE** |
| `2026-10-07T17:36:09-05:00` — the reviewed instant | `would_accept: true` | **3/3 ok** |

The future-instant rows matter on their own. My first pass tested
`2026-12-01`, which is *also* past expiry — so the expiry bound caught it and the
future bound was never exercised. I retested with instants inside both windows to
prove that check works by itself. Without it, a route dated tomorrow would pass
every other bound and the engine would accept it.

Gate 0 was exercised too: no `ROUTE_DECISION_AT` refuses, and so does supplying
the stale AM instant.

---

## D. Preflight against production, read-only

```
would_accept          true
mutated               false
destination_exists    false
predicted_record_id   CROUTE-0007
request_digest        sha256:db8962e39dcb6efb2b1a91c12ca7b97f8d2ae446e8225f226b4228144cba2e9e
request_id            g11bcar-create-route-capdef-0001-ccon-0001-cinst-000007-supersedes-croute-0006
```

| check | result |
|---|---|
| Fabric before and after | `1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb` — unchanged |
| route sequence | **6**, unmoved |
| route head | `CROUTE-0006` at `ffa04e0f578b5ae420ef01f5d38ce0e547fef56a13d2976d2923d82fce7ff3f2` |
| `CROUTE-0007` | absent from production and from `/etc` |
| `CADV-000008` | `8b478c3e…654c` ✓ |
| `CINST-000007` | `8e577b7d…85ad` ✓, lifecycle `admitted`, unsuperseded |
| `CINST-000007` eligibility | **`true`, `reasons: []`, 12/12** |

Staging for the preflight was a `mktemp -d`, not `/etc` — nothing was frozen to
perform it.

---

## E. The scratch write, and the proof the route does its job

Byte copy of production, proved equal first, then the released `create-route`:

| check | result |
|---|---|
| outcome | `accepted`, reason `null` |
| route sequence | **6 → 7** |
| route head by scan | **`CROUTE-0007`** |
| `route_version` | **7** |
| `candidate_instances` | **`[CINST-000007]`** |
| `supersedes` | `CROUTE-0006` |
| `CROUTE-0006` | `ffa04e0f…f3f2` — byte-identical |
| `fabric validate` | `findings: []`, routes 7 |
| persisted record SHA-256 | `3ab79b33558f411d76d62d1dd48dbc2c89a51420ea73caa4032698a970bb7c24` |
| post-write aggregate | `758c6c6578abdfccc7d29d2f1b7e9d56cbf4d933636853c884fb599ef70862ba` |

Then the selection preview, on the same copy:

```
through the CURRENT head CROUTE-0006:    selected_instance_id  None
through the CANDIDATE head CROUTE-0007:  selected_instance_id  CINST-000007
```

The `None` case still returns `would_accept: true` from the engine, so the old
route does not fail loudly — it would persist an accepted selection that selects
nothing. **That contrast is now a gate inside the artifact** (gate 7), printed to
the console both ways, so the operator sees the before and after rather than
being told.

The post-write values are **comparison values only**; the artifact labels the
aggregate UNKNOWN-for-production until the write. The chain-rehearsal suite
derived the same request digest and the same post-write aggregate independently
from its own copy.

---

## F. The prepared freeze artifact

`provisioning/fabric/g11-bc-ar-croute-0007-freeze.txt` — freezes exactly
`/etc/kyri/fabric/croute-0007.json`, contains **no production `create-route`**,
and refuses on:

| refusal | gate |
|---|---|
| missing `ROUTE_DECISION_AT`, or any value other than `2026-10-07T17:36:09-05:00` | 0 |
| any of the three production baselines moved | 1 |
| `CADV-000008` wrong, sequence not 8, or superseded | 2 |
| `CINST-000007` wrong, sequence not 7, superseded, or not `admitted` | 2 |
| route sequence not 6 | 3 |
| `CROUTE-0007` already present | 3 |
| `CROUTE-0006` altered or already superseded | 3 |
| `/etc/kyri/fabric/croute-0007.json` already exists | 4 |
| the body is the **stale AM route body** `6724622395…9e25` | 4 |
| the body is the `CROUTE-0005` or `CROUTE-0006` input | 4 |
| rendered digest, byte count, or **`request_id`** not the reviewed value | 4 |
| `recorded_at` before the admission, at/after its expiry, at/after the advertisement's expiry, or **in the future** | 5 |
| either governing window closed at the current clock | 5 |
| `CINST-000007` not currently eligible, or any eligibility reason | 6 |
| a selection through the candidate route not resolving to `CINST-000007` | 7 |
| wrong head, sequence, `route_version`, candidates or `supersedes` on the copy; any validate finding; `CROUTE-0006` altered | 7 |
| preflight not accepting, mutating, destination existing, wrong identity, wrong request digest, **wrong request id** | preflight |
| production Fabric changed, or the route sequence moved | post-preflight |
| `CROUTE-0007` reaching production Fabric, or a `csel-000005.json` appearing in `/etc` | post-freeze |

`provisioning/fabric/g11-bc-am-croute-0007-freeze.txt` is marked **SUPERSEDED AT
G11-BC-AR. DO NOT RUN THIS.** with its old pins intact — upgraded from the
"STALE" marking it carried since AO, now that a live replacement exists.

---

## G. Both digests are pinned, because one is not enough

G11-BC-AQ proved the request digest excludes `request_id`. The artifact therefore
pins the body SHA-256 **and** the request digest, and checks `request_id` out of
the rendered body and out of the preflight response. Pinning only the digest
would leave the request id unverified.

That is now a standing test rather than a note in a report
(`tests/test-fabric-renewal-chain-rehearsal.sh`), asked of the released engine:

| assertion | result |
|---|---|
| changing `request_id` **changes** the body SHA | PASS |
| changing `request_id` **leaves the request digest unchanged** | PASS |
| changing `actor` **does** change the request digest | PASS |

The third exists so the test cannot pass by the digest being inert. If the engine
ever starts covering `request_id`, the second assertion fails loudly and the
artifacts' reasoning gets revisited as a reviewable change rather than drifting
silently.

---

## H. Three suite checks were testing a template, not a property

Re-pinning the freeze suite for a route surfaced three checks that only ever
described an *advertisement or admission* artifact and would have forced the route
artifact to make claims it has no authority for. This is the same class of defect
I fixed at G11-BC-AO, in checks I wrote.

1. **The clock gate demanded the window come out of the body.** A route carries
   no window — it carries a decision instant and borrows its window from the
   records it depends on. The check now branches: `CADV`/`CINST` read their own
   window from the body; `CROUTE`/`CSEL` must read the decision instant from the
   body *and* the bound from a governing record file. It also dropped a literal
   `'current-time freshness gate'` phrase match, which was a spelling test the
   neighbouring comment already warned against.
2. **The containment check demanded the words "outlives the advertisement".** A
   route has no window to outlive; its instant must not fall at or after the
   advertisement expires. Now kind-aware, asserting the right property for each.
3. **The scope check demanded every artifact name `CPKG-0001`, `CHOST-0001`,
   `x86-64` and `execute`.** Those are admission fields. Demanding them of a route
   is the mirror of demanding locality of an admission — which this very suite
   already handled correctly for locality. Each kind now names its own dimensions
   and must *state where the others live*; the route artifact gained that
   paragraph, pointing at `CINST-000007`, which gate 2 pins by digest.

The route body was not touched to satisfy any of this — its digest is unchanged
at `beb687c2…2989`.

---

## I. Production state at the close

| store | aggregate | moved? |
|---|---|---|
| `/var/lib/kyri/fabric` | `1dc83d0127e3076d32d4c440ccee28f2b57ee9b6a9e84773cafaf8fa21f1d8cb` | no |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | no |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | no |

Re-measured after every rehearsal and probe. Route sequence 6, `CROUTE-0007`
absent from the store and from `/etc`.

---

## J. What this checkpoint did not do

Nothing frozen into `/etc`; no production `create-route`; `CSEL-000005` not
rendered, not prepared, not frozen — its instant must be a real operator
selection decision made after `CROUTE-0007` is written and accepted. No
capability execution, no runtime mutation, §36 and G7 not entered, ENG-0006 not
begun.

The Stage-3 gate matrix remains **8 reached / 14 masked**. It is now one
authorisation away: `CSEL-000005`.

---

## K. Validation

| run | result |
|---|---|
| `tools/dev/run-validation.sh` (full) | **165/165**, 0 FAIL, 0 FAILED, **0 host-only skips** |
| clean clone of `514b7bf` | **165/165**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `514b7bf` | **6/6 green** — Static validation, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy |

| suite | before | after |
|---|---|---|
| `test-fabric-renewal-chain-rehearsal.sh` | 12 PASS / 0 FAIL | **23 PASS / 0 FAIL** |
| `test-fabric-renewal-freeze-artifacts.sh` | 84 PASS / 0 FAIL | **87 PASS / 0 FAIL** |

The chain rehearsal gained the route step back (it is prepared again, so it is
rehearsed rather than skipped) plus the three request-digest coverage
assertions. The freeze suite gained the route's own gates; three of its checks
became kind-aware rather than template-shaped, as §H describes.

`TOTAL_STEPS` needed no change: no suite was added.

---

## L. Questions for the reviewer

1. **`create-route` accepting an out-of-order or expired `recorded_at` is still
   unfixed in the engine.** I have now proved it refuses nothing across six
   violating instants, including one dated tomorrow. Every ceremony from here
   carries the gate in its own text, which means a ceremony written without it is
   silently unprotected. Worth an ADR and an engine change rather than relying on
   each artifact's author?
2. **Gate 7 runs a selection preview inside the route freeze.** It is a throwaway
   on a copy, its request id is `g11bcar-PREVIEW-not-csel-000005`, and the block
   refuses if a `csel-000005.json` appears in `/etc`. I judged seeing
   `None → CINST-000007` on the console worth it, since "the write succeeded"
   proves nothing here. Confirm that is not too close to preparing the selection.
3. **The three template-shaped checks were mine, from G11-BC-AO.** Each passed for
   two checkpoints because every artifact in the table happened to be an
   advertisement or an admission. Is it worth a pass over the whole suite for
   checks that are satisfied by prose rather than by structure, rather than
   finding them one record kind at a time?
