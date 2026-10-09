# G11-BC-AT — the renewal is verified end to end, and O3 is closed against live production

**Date:** 2026-10-09
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `461af0b`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — `CSEL-000005` verified by content with mutation accounting PASS. Current execution authority confirmed through the released verifier against live production. **The Stage-3 BLOCK B gate matrix passes 22/22 with 0 masked against live production: O3 is CLOSED.** No production write of any kind.

---

## A. CSEL-000005, verified by content

The production write matches the G11-BC-AS rehearsal **exactly** — record and
whole store:

| | measured | expected |
|---|---|---|
| persisted record | `bc464efcee8c70b0a17678e3011a204f677f2ffb08f5afee16a4e52d8c2510f0` | identical to the AS rehearsal ✓ |
| Fabric aggregate | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` | identical to the AS rehearsal ✓ |
| runtime / Trust | `7dfb34e6…2e99` / `53605e4e…b63f` | unmoved ✓ |

**All 22 semantic checks pass** against the reviewed AS input: `selection_id`,
`route_id` `CROUTE-0007`, `route_version` 7, `selected_instance_id`
`CINST-000007`, `selected_at` `2026-10-08T03:32:26-05:00`,
`considered_candidates` `[CINST-000007]`, `excluded_candidates` `[]`,
`local_node_identity` `HOST-0001`, `kind`, `schema_version`, `selection_reason`,
five `request_class` members, and five `evidence` members including the request
digest `sha256:dd232d52…d721` and `reason_category: selection`.

Sequences: advertisement 8, instance 7, route 7, selection **5**. `fabric
validate` against production: **`findings: []`**.

### Mutation accounting: PASS

Remove `CSEL-000005`, rewind the selection sequence 5 → 4:

```
rewound:           758c6c6578abdfccc7d29d2f1b7e9d56cbf4d933636853c884fb599ef70862ba
expected pre-CSEL  758c6c6578abdfccc7d29d2f1b7e9d56cbf4d933636853c884fb599ef70862ba
```

The file-level diff shows exactly two files: `+
capability-selections/CSEL-000005.yaml` and the selection sequence file. Nothing
else moved.

---

## B. The four-record renewal, verified whole

Heads by scan — a head being a record nothing supersedes:

| kind | head |
|---|---|
| advertisement | **`CADV-000008`** |
| instance | **`CINST-000007`** |
| route | **`CROUTE-0007`** |

**Selections have no supersession.** Zero of the five selection records carry a
`supersedes` field, so the current selection is established by
`capability-selection.seq = 5` and `CSEL-000005`'s exact bytes
(`bc464efc…10f0`), not by a head scan. Saying so matters: a head check for a
record kind that has no supersession would be asserting something the store
cannot answer.

The chain resolves, every link read out of the records — **12 links, 0
failures**:

```
CSEL-000005 -> CROUTE-0007 (v7) -> CINST-000007 -> CADV-000008
CINST-000007 -> CPKG-0001, CHOST-0001, CCON-0001, CAPDEF-0001
CADV-000008  -> CPKG-0001, CCON-0001
operation `execute`, from CINST-000007's own effective_scope
```

The released verifier independently confirms the same resolution — see §C, where
its verdict carries `selection_id`, `instance_id`, `capability_package_id`,
`contract_id`, `capability_id`, `operation` and `target_node_identity` as
resolved values rather than as inputs I supplied.

### Authority is live, with a measured margin

```
now                      2026-10-09T06:23:56-05:00
CADV-000008 valid_until  2026-10-13T06:25:00-05:00    open
CINST-000007 until       2026-10-13T06:25:00-05:00    open
hours of authority left  96.0
```

**This matters for what O3's closure proof is.** The live matrix proof in §D is
evidence about a store whose authority expires in four days. It is a true
statement about production today, not a permanent property. When this window
closes the matrix will mask again — not because anything regressed, but because
current authority is a wall-clock fact. The renewal chain is the repeatable
remedy, and it is now proved end to end.

---

## C. The released authority verifier, identified exactly

The brief's caution is correct — I confirmed it rather than assuming:

```
$ python3 -m tools.fabric.cli verify-selected-evidence --help
fabric: error: argument command: invalid choice: 'verify-selected-evidence'
   (rc=2)
```

What G11-BC-AS actually used, and what I ran here:

```
module:    /usr/lib/kyri/python/tools/capability/fabric_evidence.py
function:  verify_selected_evidence
signature: verify_selected_evidence(fabric_root, *, expected_uid, expected_gid,
                                    selection_id, instance_id,
                                    capability_package_id, operation,
                                    trust_root, evaluated_at: datetime)
                                    -> EvidenceVerdict
```

The installed module is byte-identical to the repository copy —
`e51d893936ba5e465fa94893a46a3f85c66ad4904a29970f66dc00f63fb67e67` for both — so
the function I called is the released one, not a working copy.

**CLI-exposed: not as a dedicated verification subcommand; yes, read-only,
through one.** `tools/fabric/cli.py` has no verify command. The capability CLI
calls this exact function at `tools/capability/cli.py:413`, inside
`command_preflight`, which is reached by `capability invoke --preflight`
(dispatched at line 222-223 from the `--preflight` flag registered at line 1080).
That handler opens the store with `open_for_read` and runs `prepare_invocation`
under `rehearsing()`, documented to stop short of the two irreversible acts —
staging and identifier allocation. `tools/capability/coordinator.py:110` calls it
on the write path.

I did **not** run `capability invoke --preflight` here. It satisfies the stop
boundary on paper, but it drags in package staging, manifest validation and a
full source-tree traversal — a far larger surface whose unrelated failure would
be noise rather than evidence about O3 — and the question the brief asks is
answered by the released function itself. What I ran is the library call, which
is exactly what AS reported.

### Against LIVE production

```
evaluated_at         2026-10-09T06:25:38-05:00
supported            True
reason               None
eligibility_reasons  []
```

and the verdict's resolved values:

```
selection_id CSEL-000005   instance_id CINST-000007   capability_package_id CPKG-0001
contract_id CCON-0001      capability_id CAPDEF-0001  operation execute
target_node_identity HOST-0001
effect_class computational
artifact_reference   tree:kyri-execution-boundary-verification/1.0.0
manifest_reference   file:kyri-execution-boundary-verification/1.0.0.manifest.json
```

For contrast, the same verifier on the accepted pre-renewal pair
(`CSEL-000004 -> CINST-000006`) still answers `supported=False
reason=admission-window-not-open`. The renewal was append-only: history still
refuses.

---

## D. The live Stage-3 gate matrix — O3 CLOSED

Run against **live production Fabric**: no scratch store, no override, no
substituted window, no synthetic authority, no reordered gates.

| tally | value |
|---|---|
| cases present | **22 / 22** |
| fail closed | **22 / 22** |
| intended refusal | **22 / 22** |
| masked | **0** |
| tracebacks | **0** |
| PASS / FAIL | **94 / 0** |

The decisive line, which was impossible before the renewal:

```
PASS: BLOCK B passes against an unmodified fixture
```

Previously BLOCK B refused the clean fixture on `admission-window-not-open`,
which masked 14 of the 22 sabotages because the expired authority refused ahead
of their own gates. **`admission-window-not-open` now appears zero times in the
run.** Each of the 14 reaches the gate it was written for.

`O3_STATUS = CLOSED`.

Two notes on honesty here:

- The three lines mentioning "expired" in the run are **one of the 22 sabotage
  cases** — "the advertisement authority has expired", which deliberately
  expires an advertisement and requires BLOCK B to refuse with *the Fabric
  authority is not currently valid*. That case now **reaches its own gate**
  instead of being masked, which is the point.
- My first tally of the AS scratch run reported "traceback 22". That was my grep
  matching the 22 `PASS: …: no traceback` *assertions*. Actual Python tracebacks,
  here and there: **0**.

### What changed in the suite, and what did not

The matrix's four authority defaults named the **pre-renewal** chain, so running
it with no overrides would have tested `CSEL-000004 → CINST-000006` — the expired
pair — rather than live production. The defaults now name what production
actually carries:

```
CSEL-000004 -> CSEL-000005      CROUTE-0006 -> CROUTE-0007
CINST-000006 -> CINST-000007    CADV-000007 -> CADV-000008
```

The override mechanism is untouched, so the chain rehearsal still points the same
gates at a scratch chain. **No assertion was changed, removed or weakened.** Two
prose claims were corrected because they stated expiry as a standing fact:

1. `"the reviewed Fabric chain is present, byte-identical — expired, and NOT
   renewed to make a gate pass"` asserted expiry in a message whose assertion is
   byte-identity. It now says the chain is carried as it stands, with no window
   edited.
2. A comment said the fixture "carries the reviewed chain, expired, because that
   is what the reviewed chain is". It now records that the chain was expired
   while `CADV-000007`/`CINST-000006` were the heads and is live now, and that
   the suite still never declares which — `FABRIC_EXPIRED` is derived from what
   BLOCK B actually printed.

That measured-not-declared design is why this checkpoint needed no gate surgery:
the suite already failed closed on *"cases were masked while the Fabric authority
is live: that is not masking, it is a defect"*, so a live chain with any masking
would have been a failure rather than a pass.

---

## E. Baseline accounting

The completed baseline now exists, so it is named — **after** the write, not in
anticipation of it:

```
a87c2010…12e5  the post-CSEL-000004 store this ceremony was reviewed against
d11c939a…562c  after the accepted CADV-000008 renewal write, G11-BC-AO
1dc83d01…d8cb  after the accepted CINST-000007 admission write, G11-BC-AQ
758c6c65…62ba  after the accepted CROUTE-0007 route write, G11-BC-AS
7e2a4ed0…f376b after the accepted CSEL-000005 selection write, which completes
               the renewal, G11-BC-AT
```

Five entries, each an explicit 64-character digest with a stated provenance, each
reconstructible from the store it names. The comparison is exact equality against
that named set (`[[ "${PRODUCTION_FABRIC_BEFORE}" == "${entry%%|*}" ]]`) — no
wildcard, no current-state acceptance, no "whatever exists". An unaccounted store
still fails, which is how this set earned its last two entries: the validator
refused the post-route baseline at G11-BC-AS and the post-admission one at
G11-BC-AQ before each was reviewed in.

---

## F. Validation

| run | result |
|---|---|
| **live Stage-3 matrix** | **94 PASS / 0 FAIL — 22/22, 0 masked** |
| Stage-0 rehearsal | 15 PASS / 0 FAIL |
| Stage-1 rehearsal | 26 PASS / 0 FAIL |
| Stage-2 spent rehearsal | 31 PASS / 0 FAIL |
| Stage-3 spent rehearsal | 34 PASS / 0 FAIL |
| Fabric chain rehearsal | 37 PASS / 0 FAIL |
| freeze-artifact suite | 90 PASS / 0 FAIL |
| no-production-escape | 4 PASS / 0 FAIL |
| static (incl. 197 ShellCheck conformance assertions) | all passed |

Governed stores measured around the whole executable group:

| store | before | after |
|---|---|---|
| Fabric | `7e2a4ed0…f376b` | **UNCHANGED** |
| runtime | `7dfb34e6…2e99` | **UNCHANGED** |
| Trust | `53605e4e…b63f` | **UNCHANGED** |

The chain rehearsal fell 42 → 37 PASS with no edit to its assertions: with
`CSEL-000005` now written, all four steps report **ALREADY WRITTEN — verifying,
not rehearsing**, and the selection's eight rehearsal assertions become three
verification ones. Its completion path still runs in full, reporting
`supported=True`, that the accepted pair still refuses, no findings, no authority
broadened, and the matrix at 22/0.

---

## G. Carry-forward findings for §36

Recorded, not fixed — none of them blocks the audit:

1. **`create-route` accepts temporally impossible `recorded_at` values.** Proved
   at G11-BC-AQ and re-proved at AR across six instants: the engine returns
   `would_accept: true` for a route recorded before its candidate's admission,
   and for one recorded after both governing windows close.
2. **`select` can report `would_accept: true` while resolving
   `selected_instance_id: null`.** Proved at AS across eight instant pairs. The
   engine never refuses on temporal grounds; outside the window it resolves to
   null, which would persist an accepted selection that selects nothing.
3. **`request_digest` does not cover every request-body member** — specifically
   not `request_id`. Proved for `create-route` at AQ and for `select` at AS:
   changing only `request_id` leaves the digest identical, while `actor`,
   `recorded_at` or `local_node_identity` change it. The freeze artifacts
   therefore pin the body SHA-256 *and* the digest, and read `request_id` out of
   the body.
4. **Kind-specific assumptions in the matrix and freeze-artifact suites.** Three
   freeze-suite checks demanded advertisement/admission prose of a route (AR);
   the matrix's authority defaults named the pre-renewal chain and two of its
   messages asserted expiry as a standing fact (this checkpoint). All were mine.
   The pattern is checks satisfied by prose rather than by structure, and they
   pass until a different record kind or a changed world arrives.

Findings 1 and 2 together mean **two of the four renewal verbs enforce no
temporal ordering at all**; the protection lives entirely in the freeze
artifacts' gate text. That is the fourth checkpoint to raise it.

---

## H. Production state at the close

| store | aggregate |
|---|---|
| `/var/lib/kyri/fabric` | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |

No Fabric record written; `select` not re-run; no capability executed;
`CRES-000002` byte-identical and no `CRES-000003`; no runtime, lifecycle, CADM,
CINV, CRES or CMUT mutation; nothing renewed again; G7 not entered; nothing
merged, tagged or released; no evidence cleaned; ENG-0006 not begun.

---

## I. Questions for the reviewer

1. **O3's closure is a wall-clock-bounded fact.** The matrix passes 22/0 today
   because authority is live for another 96 hours. After `2026-10-13T06:25:00`
   it will mask again with nothing regressed. Should the audit record O3 as
   closed with the evidence dated, or should closure require something
   time-independent — for instance the suite asserting that masking is *always*
   attributable, which it already does?
2. **I changed the matrix's authority defaults.** They pointed at the expired
   pair, so the no-override run tested the wrong chain. I treated that as
   required by the brief's "no overrides, live production" and changed no
   assertion. Confirm that reading — the alternative was passing four overrides
   and reporting a run the default configuration does not reproduce.
3. **Findings 1 and 2 are now four checkpoints old.** Two renewal verbs accept
   temporally impossible records and the only protection is artifact prose. If
   §36 is the place to decide, this is the input; if it warrants an ADR and an
   engine change first, that is a scope call I should not make.
