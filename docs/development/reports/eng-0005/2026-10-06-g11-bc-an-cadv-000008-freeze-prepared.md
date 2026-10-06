# G11-BC-AN — a fresh observation, and every number that depended on it

**Date:** 2026-10-06
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `6ed35d9fbaab3dff2494dd9a510ac2ee709d53ce`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — CADV-000008 is reviewed, rehearsed and preflighted against production. **The `/etc` freeze itself was not performed: this account cannot write `/etc/kyri/fabric`, so that step is the operator's.** No production Fabric write. Production Fabric, runtime and Trust unmoved.

---

## A. Production, rehydrated read-only

| gate | measured |
|---|---|
| repository HEAD | `6ed35d9fbaab3dff2494dd9a510ac2ee709d53ce` — **the accepted checkpoint**, clean tree |
| Fabric aggregate | `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` — **matches** |
| runtime aggregate | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` — matches |
| Trust aggregate | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` — matches |
| advertisement sequence | **7** |
| advertisement records | 7 |
| advertisement head | **CADV-000007** — derived by scanning for a record nothing supersedes, not by taking the highest number |
| CADV-000007 digest | `24689fba6e1652e8adecb63eb0c1dabb2e263456067ad4ed0df843914d098d9c` — immutable |
| CADV-000007 window | `2026-09-19T06:00:00-05:00` → `2026-09-23T06:00:00-05:00`, **expired 13 days** |

## B. The window, and the policy that derives it

The G11-BC-AM window was tied to **that** checkpoint's preparation instant,
`2026-10-05T15:00:00-05:00`. A production observation performed later must not
carry it, so the observation was made again — read-only, against production, in
this checkpoint.

| | | |
|---|---|---|
| `observed_at` | **`2026-10-06T06:25:00-05:00`** | the observation performed here |
| `recorded_at` | `2026-10-06T06:25:00-05:00` | the reviewed recording instant |
| `valid_until` | **`2026-10-13T06:25:00-05:00`** | `observed_at + 7 days`, the reviewed expiry policy |

**The policy is checked against the bytes, not merely written beside them.** The
artifact re-derives `observed_at + 7 days` from the rendered body and refuses if
it is not what the body says, so the policy cannot drift from the record it
describes. It also applies the engine's own half-open interval to the body's own
recording — `observed_at <= recorded_at < valid_until` — and the operator's wall
clock to the window.

### The timestamp policy, explicit

**The operator supplies the observation instant.** The artifact refuses without
`OBSERVED_AT` in the environment, and refuses if what is supplied is not the
instant the reviewed bytes carry:

```
OBSERVED_AT=2026-10-06T06:25:00-05:00 bash <the freeze block>
```

That is deliberate on both sides. The instant is inside the reviewed body, so it
cannot be chosen at the keyboard — every dependent digest derives from it. But it
must also be **asserted by the person performing the observation** rather than
assumed by the artifact, and a mismatch means the chain is re-prepared rather than
nudged.

**No clock is read to supply a value.** `date`, `now()` and their equivalents
appear in exactly one place — the gate that **refuses** — and never in the
rendering. The frozen bytes carry the reviewed timestamp before production Fabric
is touched.

**If the window closes before the write**, the artifact refuses and says to
re-prepare from a fresh observation. It is designed to refuse, not to be edited.

## C. The cadence was wrong first, and the engine caught it

Worth recording, because it is a constraint that is not obvious from the record
shapes.

My first cadence ran **forwards** from the observation — advertisement 06:25,
instance 06:40, route 06:55, selection 07:05 — which is the natural reading of
"these events happen in order". The rehearsal then refused:

```
verdict: supported=False reason=admission-window-not-open eligibility=[]
```

`_window_open` requires `start <= instant < end`, and the instance's
`admitted_at` was ten minutes in the **future**. A window that has not opened is
not an open one.

So the cadence runs from the observation through the decisions recorded during
this preparation, **every instant already past**:

| record | instant | |
|---|---|---|
| CADV-000008 | `2026-10-06T06:25:00-05:00` | the observation |
| CINST-000007 | `2026-10-06T06:25:30-05:00` | the admission decision |
| CROUTE-0007 | `2026-10-06T06:26:00-05:00` | the route |
| CSEL-000005 | `2026-10-06T06:26:30-05:00` | the selection |

Second granularity, not minute: at minute granularity the selection's
`evaluated_at` sat a minute ahead of the clock, which would have claimed an
evaluation nobody had performed.

## D. Nothing stale was carried forward

Every value that depended on the window was recomputed. **The rehearsal refused
the stale pins before they were recomputed**, which is what the pins are for:

```
FAIL: g11-bc-am-cadv-000008-input.json is f6831045…, not the reviewed f0e97487…
FAIL: the reviewed inputs do not match; nothing below would prove the right chain
```

| record | input digest | bytes | request digest | chain post-baseline |
|---|---|---|---|---|
| **CADV-000008** | `f683104575018b4b77c15852e08358765a3dc70a6677a22938c4cc54a55fcc61` | **674** | `sha256:3a357992…9a28` | `d11c939a…562c` |
| CINST-000007 | `cc4e8fe6…ab78` | 1270 | `sha256:3105868c…390a` | `39dc7ebb…48cf` |
| CROUTE-0007 | `67246223…9e25` | 679 | `sha256:093bb383…6279` | `4a0f15aa…8487` |
| CSEL-000005 | `2480aac0…785b` | 606 | `sha256:a5b5700c…2371` | `d97f85ea…8d26` |

The suite now also refuses any G11-BC-AM instant surviving as a **pinned value**
in any artifact — they may appear only in prose explaining why they were replaced.

## E. The production preflight

Read-only, against production Fabric, from a staging directory that is not
`/etc`:

```json
{
  "destination": "/var/lib/kyri/fabric/capability-advertisements/CADV-000008.yaml",
  "destination_exists": false,
  "mutated": false,
  "predicted_record_id": "CADV-000008",
  "request_digest": "sha256:3a35799239002a7ee9ee09b6002fd804bdc436030d7a3cb66d17d089f7be9a28",
  "request_id": "g11bcan-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000007",
  "would_accept": true
}
```

And afterwards: Fabric aggregate `a87c2010…12e5` **byte-identical**, advertisement
sequence **still 7**. The request digest is the one the scratch rehearsal produced
for the same bytes, which is the cross-check that matters: the production engine
and the rehearsed engine agree.

## F. The freeze itself is the operator's step

**I did not write `/etc/kyri/fabric/cadv-000008.json`**, and could not:

```
/etc/kyri/fabric   drwxr-x---  root:cschott
sudo: a password is required
```

`sudo` is not available non-interactively to this account, and the freeze needs
root. So the artifact is prepared and the freeze is pending the operator:

`provisioning/fabric/g11-bc-an-cadv-000008-freeze.txt` — **72 assertions pass**
against it in the freeze-artifact suite. It performs, in order: the
operator-supplied instant gate · the three production baselines · the
advertisement head, its immutability and its expiry · the reviewed body from the
repository with two predecessor bodies refused by name · the window and policy
gate · the **read-only preflight** · the Fabric-unchanged proof · then one
`install` of one file into `/etc` · then the governed stores re-measured and a
proof that `CADV-000008` did **not** reach production Fabric.

**The `register-advertisement` write is not in it.** That remains a separate
authorisation, and CINST-000007, CROUTE-0007 and CSEL-000005 are not frozen.

### The superseded artifact

`g11-bc-am-cadv-000008-freeze.txt` is marked **SUPERSEDED AT G11-BC-AN — DO NOT
RUN THIS**, names its replacement, and **keeps its old pins deliberately**: a
superseded artifact carrying current numbers would be indistinguishable from a
live one, and two live artifacts for one record is exactly the mis-paste these
artifacts refuse by name. The suite asserts all three of those things.

## G. Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **140/140**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| `run-validation.sh` (full) | **165/165**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| clean clone, full | *(CLONE)* |
| GitHub CI | *(CI)* |

This checkpoint's suites: renewal-chain rehearsal **58** · freeze artifacts
**72** · Stage-3 gate matrix **74** (production: 8 reached, 14 masked, unchanged)
· no-production-escape **4** · static **865** · docs-static **993** ·
developer-experience **141** — all 0 FAIL. ShellCheck clean.

The rehearsal with the new window: every released write accepts, every predicted
identifier matches, every sequence advances by exactly one, `fabric validate`
reports no findings, the verifier reports **`supported=True`**, and the Stage-3
matrix reaches **22/22 intended refusals with 0 masked** against the renewed
chain.

## Questions for the reviewer

1. **The recorded_at policy.** `recorded_at` equals `observed_at`, which is
   truthful for the observation but means the *write* is a later event the record
   does not timestamp separately. The artifact bounds that by refusing outside the
   window. The tighter alternative is to have the operator render the body at
   write time — I did not do it, because it moves reviewed bytes out of review.
   Which do you want?
2. **The `/etc` freeze.** It needs root. Run the prepared artifact yourself, or
   would you rather I be given a path that does not need `sudo`?
3. **Order after this.** Freeze CADV-000008, authorise its write, then step 2 of
   4 — with the downstream artifacts' pins already recomputed for this window?

---

## What was NOT done

CADV-000008 was not written to production Fabric. Nothing was frozen into `/etc`.
CINST-000007, CROUTE-0007 and CSEL-000005 were not frozen. Nothing else was
renewed. No capability was executed. No lifecycle, runtime, CADM, CINV, CRES or
CMUT was mutated. The §36 audit was not entered. G7 was not entered. ENG-0006 was
not begun.
