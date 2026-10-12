# ENG-0005 G11-AZ-B — CROUTE-0003 production write, accepted

**Status: accepted.** `CROUTE-0003` is written to production and independently
verified from the stored record, not from the CLI's report of itself.

Follows **[G11-AZ-A](2026-09-03-g11-az-a-croute-0003-preparation.md)**, which
prepared the candidate, and **[G11-AY-D](2026-09-03-g11-ay-d-cinst-000003-production-write.md)**,
which accepted the `CINST-000003` write this route now names.

Branch `arch/eng-0005-execution-transition`, HEAD `600d82c` at the write.

---

## 1. Production CLI output

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CROUTE-0003",
  "record_kind": "capability-route",
  "request_digest": "sha256:970d926ccdafce77cac9d7c1869b61c8f744515847172780b45849de3fd4a3dc",
  "request_id": "g11az-create-route-capdef-0001-ccon-0001-cinst-000003-supersedes-croute-0002"
}
```

**This output is not the evidence.** Everything below was read back off disk.

The request digest `sha256:970d926c…d4a3dc` now stands at one value across four
independent runs: the AZ-A fixture preflight, the AZ-A fixture write, the AZ-A
live preflight, and this accepted write. The stored record carries it too — §2.

## 2. The record, read from production

`/var/lib/kyri/fabric/capability-routes/CROUTE-0003.yaml` —
`cschott:cschott 0600`, **885 bytes**, stored digest
`18d54f8a6f8201362a827c940bee3d42ea8cd792d69005a5ed96a3bdff8bb22a`.

| governed field | required | stored | |
| --- | --- | --- | --- |
| `route_id` | `CROUTE-0003` | `CROUTE-0003` | ✓ |
| `route_version` | `3` | `3` | ✓ |
| `supersedes` | `CROUTE-0002` | `CROUTE-0002` | ✓ |
| `candidate_instances` | exactly `["CINST-000003"]` | `[CINST-000003]` | ✓ |
| `capability_id` | `CAPDEF-0001` | `CAPDEF-0001` | ✓ |
| `contract_id` | `CCON-0001` | `CCON-0001` | ✓ |
| `accepted_contract_versions` | `["1.0.0"]` | `[1.0.0]` | ✓ |
| `data_classification` | `internal` | `internal` | ✓ |
| `locality` | `local-only` | `local-only` | ✓ |
| `overlap_window` | **absent** | **absent** | ✓ |

`reason_category: supersession`. `causal_references: [CAPDEF-0001, CCON-0001,
CINST-000003, CROUTE-0002]`. `trust_evidence_references: []`.

**`candidate_instances` names `CINST-000003` and nothing else.** The superseded
`CINST-000002` is not carried, and no overlap window is declared — the prior
accepted ruling against carry-both is honoured. AZ-A §2 recorded that the source
does not enforce that ruling; it was held by review, and the stored record shows
it held.

## 3. Sequence

```
capability-route.seq   2  ->  3
```

Advertisement, instance and selection sequences unmoved at **4 / 3 / 1**.

Both representations are 2 bytes (`2\n` → `3\n`), so a structural manifest
reports this file as unchanged. Only content accounting sees it — §6.

## 4. Head

Derived by raw set difference over all route IDs minus every `supersedes`
target, not assumed:

```
all routes  : CROUTE-0001, CROUTE-0002, CROUTE-0003
superseded  : CROUTE-0001, CROUTE-0002
heads       : CROUTE-0003        (exactly one)

CROUTE-0001 v=1 candidates=[CINST-000001] supersedes=None
CROUTE-0002 v=2 candidates=[CINST-000002] supersedes=CROUTE-0001
CROUTE-0003 v=3 candidates=[CINST-000003] supersedes=CROUTE-0002
```

**`CROUTE_HEAD = CROUTE-0003`.** No fork, no ambiguity. The chain is linear and
each version exceeds the one it supersedes.

## 5. Predecessor non-mutation

`CROUTE-0002` after the write:

```
1a7ed01877751ef70c8c25012cd947b23be9aa9a9c8cc17dacb6e79eba343870
```

**Byte-identical** to the value recorded for it before this write, in
[G11-AY-D §10](2026-09-03-g11-ay-d-cinst-000003-production-write.md) and in the
AZ-A preparation. `CROUTE-0001` likewise unchanged at
`6bf6aa0f06ff13e9787f7313d17f12f11d61de07b3cf4b9b8e26a7f191c48707`.

Supersession is recorded in the *successor's* `supersedes` field. Nothing edits
the predecessor, which is the append-only model ADR-0012 states.

## 6. Mutation accounting

**Structural manifest** — paths, owners, modes, sizes:

```
+ capability-routes/CROUTE-0003.yaml   cschott:cschott  600  885
```

That is the entire structural delta. The sequence replacement is invisible to
it.

**Content manifest** — per-file digests:

```
CREATE   capability-routes/CROUTE-0003.yaml   18d54f8a…bb22a
REPLACE  sequences/capability-route.seq       53c234e5… -> 1121cfcc…
REMOVE   (none)
unchanged  22 of 23 pre-existing files
```

**Proved by reconstruction.** The pre-write Fabric content-manifest aggregate
was recorded in AY-D §10 and re-confirmed at the close of the AZ-A preparation
as `f56503b280d4b86f1eb9addfcc5d98eda128e1a346ef07076c90219f1086e56d`. Taking
the post-write manifest, removing the `CROUTE-0003` line and reverting only the
route sequence digest to that of `2\n` reproduces:

```
reconstructed pre-write : f56503b280d4b86f1eb9addfcc5d98eda128e1a346ef07076c90219f1086e56d
recorded    pre-write   : f56503b280d4b86f1eb9addfcc5d98eda128e1a346ef07076c90219f1086e56d   MATCH
```

Had anything else moved by one byte, the reconstruction would not have landed on
the recorded value. **Exactly two changes occurred, and they are the two
intended ones.** Post-write aggregate:
`ef054d64e48d74b5b4dd1d8d8294f0add7773165ab9c975daf1b375f2ebcd8f5`.

Corroborated by modification times — the only Fabric paths touched at the write
are the new record, the route sequence, and the `capability-routes` directory
entry.

**Surfaces this write did not touch:**

| | |
| --- | --- |
| `CADV-000004` | `965499a3…4af708` unchanged |
| `CINST-000003` | `5b83135d…c21d1` unchanged |
| `CINST-000002` | `5cfcf01e…e3f719` unchanged |
| `CROUTE-0002` | `1a7ed018…43870` unchanged |
| `CSEL-000001` | `e08a4df4…e79bb` unchanged |
| Trust store | no file modified today; `valid: true`, counts unmoved |
| runtime | no `/usr/lib/kyri` or `/usr/libexec` object modified today |
| helpers | `74b84015…125874`; **`compatible`**, 8 declared, 0 blocking |
| identity authorities | `3dec888c…` / `891beeeb…` unchanged |
| Root Authority | `/mnt/kyri-root` **unmounted** |

## 7. Validation and current standing

```
fabric validate   status: reported   findings: []
                  counts 4 / 3 / 3 / 1  (advertisements / instances / routes / selections)

trust validate-store   valid: true   problems: []
                       counts  audit 4, authority 1, decision 2, evidence 7, lineage 3, record 2
```

`FABRIC_VALID = YES`, `FABRIC_DEFECTS = 0`, `TRUST_VALID = YES`.

**`CINST-000003` remains eligible and current**, re-evaluated through the
released engine at `2026-09-03T14:04:04-05:00` — after the route write, not
carried forward from AY-D:

```
eligible : true
unmet    : []
ELIG-1 .. ELIG-12   all met
```

## 8. Routability

The conjunction now holds, for the first time in this renewal:

| | |
| --- | --- |
| sole route head | `CROUTE-0003` |
| its `candidate_instances` | `[CINST-000003]` |
| `CINST-000003` lifecycle | `admitted` |
| `CINST-000003` binding root | itself |
| `CINST-000003` eligibility now | **eligible**, all twelve conditions met |

**`NEW_INSTANCE_ROUTABLE = YES`.** The renewed binding is reachable through the
released route path.

`CSEL-000002` is **absent** and the selection sequence is still **1**. Routable
is not selected: no selection record names `CROUTE-0003` yet, so nothing has
resolved a request class against it in production. That resolution is verified
in the AZ-C preparation, by read-only preflight only.

## 9. Invocation authority

```
PRODUCTION_CINV_COUNT = 0
PRODUCTION_CRES_COUNT = 0
capability-invocations / capability-results directories   do not exist
handoff root entries                                      0
sudoers non-README                                        0
```

`SUDOERS_CLOSED = YES`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

Routability is not authority. A route declares which bindings *may* serve a
class; it grants nothing, and no privileged grant exists for anything that would
execute.

## 10. What remains

The Fabric chain is now renewed at its advertisement, its instance **and** its
route. It is not renewed at its selection.

Next: **G11-AZ-C** — derive `CSEL-000002` from the **live written**
`CROUTE-0003`, prepare and preflight only. Then **G11-BA** (narrow sudoers and
final preflight), and only then **G11-BB**, the first controlled invoke.

`CSEL-000001` is historical and immutable. Route-head movement does not
invalidate it; selection eligibility is rechecked at use. It is not modified.
