# G11-BC-AO — the advertisement is written, the admission is prepared

**Date:** 2026-10-06
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `2971a5a`
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — CADV-000008 verified by content; CINST-000007 re-derived, preflighted and its freeze artifact prepared. **Neither frozen nor written.** No production Fabric mutation.

---

## A. CADV-000008, verified by content

| check | result |
|---|---|
| persisted SHA-256 | `8b478c3e8d3ed6c86a63d4dde1901cedfd56d9736b28017cfd384fa78443654c` ✓ |
| request digest in the record | `sha256:3a35799239002a7ee9ee09b6002fd804bdc436030d7a3cb66d17d089f7be9a28` ✓ |
| advertisement sequence | 7 → **8** ✓ (8 records) |
| CADV-000007 | `24689fba6e1652e8adecb63eb0c1dabb2e263456067ad4ed0df843914d098d9c` — **immutable** ✓ |
| advertisement head | **CADV-000008**, by scanning for a record nothing supersedes ✓ |
| `fabric validate` | `status: reported`, **`findings: []`** ✓ |
| live Fabric aggregate | `d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c` ✓ |
| runtime / Trust | `7dfb34e6…2e99` / `53605e4e…b63f` — unmoved ✓ |

Semantic fields all match: `CHOST-0001`, `CPKG-0001`, `CCON-0001`, version
`1.0.0`, `x86-64`, `supersedes: CADV-000007`, `observed_at` and `recorded_at`
`2026-10-06T06:25:00-05:00`, `valid_until 2026-10-13T06:25:00-05:00`.

**The live aggregate is the number the G11-BC-AN scratch rehearsal predicted**,
which is the cross-check that matters most: the rehearsed engine and the
production engine produced the same store, byte for byte.

### The mutation is bounded, not merely plausible

On a copy: remove `CADV-000008`, rewind the advertisement sequence 8 → 7,
recompute:

```
rewound:           a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5
expected pre-CADV: a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5
```

**Exact.** So the production mutation was `+ CADV-000008` and
`+ advertisement sequence 7 → 8`, **and nothing else**.

## B. The new baseline

`d11c939a5722beb9e7edb98de9970cfb3c87e93ffb78133cc1ff0b9479ca562c`

Every CINST gate is pinned to it. `a87c2010…` is the **pre-CADV** store and now
gates nothing: the artifact's comment says so where the value sits, so a reader
cannot mistake one for the other.

## C/D. CINST-000007 — re-derived, because the old instant was not truthful

G11-BC-AN's body carried `admitted_at 2026-10-06T06:25:30-05:00` — thirty seconds
after the advertisement observation, a **cadence slot** chosen while the whole
chain was rehearsed together. §D forbids backdating solely for cadence, and the
objection is sharper than staleness: **an admission is a decision by the
operator**, with `actor` and `approving_authority` both
`primary-platform-operator`. Thirty seconds after an advertisement is not when
anybody decided anything.

So it was re-derived, and everything downstream of the bytes with it.

| | |
|---|---|
| `admitted_at` / `recorded_at` / `evaluated_at` | **`2026-10-06T13:35:00-05:00`** — already reached |
| `admitted_until` | **`2026-10-13T06:25:00-05:00`** — equal to CADV-000008's close, so it cannot outlive it |
| `advertisement_id` | **CADV-000008** |
| `supersedes` | **CINST-000006** |
| body SHA-256 | **`e1bdd53e6e402c8d3f44b158cfc8601e217f701f9c33d08d1fdc622e95b4dd17`** |
| bytes | **1270** |
| request digest | **`sha256:7eb452fd0113314fe07bc335da34da2b4c6ca937bd550d74f0a5fcae95fbf2b6`** |
| predicted record | **CINST-000007**, instance sequence 6 → 7 |

**Scope, checked field by field against CINST-000006** — `capability_id`,
`capability_package_id`, `capability_host_id`, `contract_id`,
`satisfied_contract_versions`, `verified_resource_profile`, the whole
`admission_scope` (`CAPDEF-0001` / `execute` / `internal` / `HOST-0001`), and
both trust records `TREC-000001` / `TREC-000002`: **all equal**. Only the window
and the governing advertisement move.

**Locality is not an instance field.** `local-only` lives on the route and the
selection. The artifact says that rather than pretending to pin it — an admission
artifact claiming authority over locality would be claiming authority over a
record it does not touch.

### The production preflight

```json
{ "destination_exists": false, "mutated": false,
  "predicted_record_id": "CINST-000007",
  "request_digest": "sha256:7eb452fd0113314fe07bc335da34da2b4c6ca937bd550d74f0a5fcae95fbf2b6",
  "would_accept": true }
```

Afterwards: Fabric `d11c939a…562c` **byte-identical**, instance sequence **still
6**.

## And a digest I pinned from memory, which the measurement caught

`CINST-000006`'s persisted SHA went into the artifact as
`5a320fa0cb9f678d7e2f9e7ac4e5adbbd0fad6aa4c5f15e04e71cfd0a4e18a87`. I had the
first sixteen characters from an earlier dump and **filled in the rest**. It is
`5a320fa0cb9f678d3f78a11416beec17945b06add25446fbae7e0e1bf5575b9b`.

A fabricated digest in a gate is worse than a missing one: it would have refused
the correct record and sent an operator looking for tampering that never
happened. It surfaced because I verified **every** pinned value in the artifact
against its real source instead of trusting any of them, and that check is why it
exists. All nine now verify.

## E. The CINST-000007 freeze artifact

`provisioning/fabric/g11-bc-ao-cinst-000007-freeze.txt` — **78 assertions pass**
against the freeze-artifact suite. In order, it:

| | |
|---|---|
| 1 | gates the Fabric baseline `d11c939a…562c` |
| 2 | gates CADV-000008's persisted SHA `8b478c3e…654c` |
| 3 | requires CADV-000008 the advertisement head, sequence 8 |
| 4 | requires instance sequence **6** |
| 5 | requires CINST-000007 **absent**, CINST-000006 immutable and unsuperseded |
| 6 | gates the wall clock against **both** windows, reading them out of the body and the persisted advertisement |
| 7 | computes **current eligibility on a copy carrying the candidate** — `eligible: true`, no reasons, and on that copy it becomes the head at sequence 7 |
| 8 | runs `admit-instance --preflight` against production |
| 9 | proves `would_accept` / `mutated` / `destination_exists` / predicted identity / request digest, each separately |
| 10 | proves production Fabric byte-identical and the sequence still 6 |
| 11 | freezes exactly one file, `/etc/kyri/fabric/cinst-000007.json` |
| 12 | re-measures Fabric, runtime and Trust, and proves CINST-000007 did not reach production Fabric |

**The `admit-instance` write is not in it.** The operator asserts the admission
instant via `ADMITTED_AT=…`; the artifact refuses without it and refuses a
mismatch, directing a re-preparation rather than an edit.

**I did not freeze it.** `/etc/kyri/fabric` is `root:cschott 0750` and `sudo`
needs a password, so that step is the operator's — as it was at G11-BC-AN.

## F. The scratch rehearsal

Against a copy of the **post-CADV** store: instance sequence 6 → **7**,
CINST-000007 becomes the **instance head**, binds `advertisement_id:
CADV-000008`, `lifecycle_state: admitted`, `supersedes: CINST-000006`, current
eligibility **`eligible: true` with no reasons**, `fabric validate` findings
`[]` with 7 instances.

```
SCRATCH_POST_CINST_FABRIC_BASELINE =
  ca6ca22307ece7b49fbfa2cdc91a6534a90553a1481d297ee8079ce34cbfbafb
```

**A comparison value, not a baseline.** It becomes production's only if and when
the operator writes the record.

## The suites now advance with the chain

Two things had to change, and both were the suites describing a world that had
moved.

**A written step is verified, not rehearsed.** The rehearsal asked production
which chain records exist and found `CADV-000008`. It now verifies that one — the
sequence where its accepted write left it, that it is the head, that it carries
the request digest it was written from — and rehearses only what remains. A suite
that rehearsed an already-written step refuses on `destination_exists` and calls
the operator's accepted write a failure.

**Only the prepared steps are rehearsed.** Re-deriving the admission made the
route and selection bodies inconsistent with it: their instants sit at 06:26,
before the admission at 13:35, and the engine judges eligibility **at the instant
a request names**. A selection evaluated before its candidate was admitted selects
nothing — and the released engine says exactly that:
`selection-recorded-no-instance`. Rehearsing a body that will be re-derived before
it is written proves nothing about what gets written, so both artifacts are marked
**STALE AFTER G11-BC-AO — DO NOT RUN THIS** on the file, keep their old pins
deliberately, and are skipped with the reason stated.

**So the whole-chain authority verdict and the Stage-3 gate matrix do not run
here.** Current authority is a selection resolving to an admitted instance, and
there is not one yet. The suite says that rather than returning a refusal that
would read as a defect. Both return when CROUTE-0007 and CSEL-000005 are
prepared.

Against production the Stage-3 matrix is **unchanged**: 22/22 present, 22/22 fail
closed, 8 reaching their own refusal, 14 masked by the expired *selection*
authority.

### Five checks that were testing prose, and one real gap

The freeze-artifact suite failed the new artifact six times, and five were the
suite's fault: which window field a record carries (`valid_until` for an
advertisement, `admitted_until` for an admission), how a closed window is worded,
whether the request digest is pinned by literal or by a variable the artifact
pins, whether the write-separation sentence wraps across a comment line, and
counting a scratch-root invocation as if it had to be a preflight. They are
kind-aware and property-level now. The sixth was real: the artifact did not say
where `local-only` is carried, and now does.

## Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **140/140**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| `run-validation.sh` (full) | **165/165**, 0 `FAIL:`, 0 `HOST_ONLY_SKIP` |
| clean clone at `7561c22`, full | **165/165**, 0 `FAIL:`, **18 `HOST_ONLY_SKIP`** |
| GitHub CI at `7561c22` | CI, ShellCheck, CodeQL, Semgrep, Gitleaks, Trivy — **6/6 success** |

The clean clone's 18 skips are the intentional pinned-checkout refusal, every one
of which ran for real in the host run, which had 0 skips.

This checkpoint: freeze artifacts **78** · renewal-chain rehearsal **19** ·
Stage-3 gate matrix **74** · no-production-escape **4** · fabric-runtime **8336**
· capability-fabric **538** · route-head **30** · instance-admission-integrity
**38** · static **865** · docs-static **993** · developer-experience **141** —
all 0 FAIL. ShellCheck clean.

## And two spent-mode rehearsals that gated on a Fabric head

The first full run stopped at the CINV-000003 Stage-0 rehearsal:

```
FAIL: production Fabric is d11c939a…, not the pinned a87c2010…
```

Both the Stage-0 and Stage-1 rehearsals already carried the comment naming this
exact hazard — *"a whole-store aggregate in spent-mode evidence is the defect that
broke the CINST-000006 spent mode when CROUTE-0006 landed"* — and then gated on
precisely that. The accepted advertisement renewal moved the Fabric aggregate, so
two rehearsals about the **capability runtime** failed on a Fabric head neither
depends on.

They now accept a **named list** of Fabric states the repository can account for —
the store each ceremony was reviewed against, and the store after the accepted
CADV-000008 write — and anything else still fails. That is not "whatever is
there": a later renewal adds a reviewed line, which is a reviewable edit. The
assertion that always held is unchanged and is where the real guarantee lives:
whatever the aggregate was, the run must not move it.

## Questions for the reviewer

1. **The admission instant.** `2026-10-06T13:35:00-05:00`, asserted by the
   operator at freeze time. If the admission decision is genuinely later, the
   artifact refuses and the body is re-prepared — which is the honest behaviour
   but costs a round trip. Accept, or would you rather the body be rendered at
   freeze time from an instant the operator supplies?
2. **The route and selection.** Their bodies must be re-derived against the store
   as it stands when their checkpoints come — the admission instant moved, so
   theirs must too. Confirm that is the sequence you want, one record per
   checkpoint.
3. **The Stage-3 matrix.** It cannot reach 22/22 until the selection is prepared.
   That is now a stated dependency rather than a masked count; nothing is needed
   from you until then.

---

## What was NOT done

CINST-000007 was not written to production Fabric and was not frozen into `/etc`.
CROUTE-0007 and CSEL-000005 were not frozen. No capability was executed. The
execution runtime, lifecycle, CADM, CINV, CRES and CMUT were not mutated. The §36
audit was not entered. G7 was not entered. ENG-0006 was not begun.
