# ENG-0005 G11-AZ-D — CSEL-000002 production write, accepted

**Status: accepted.** `CSEL-000002` is written to production and independently
verified from the stored record, not from the CLI's report of itself.

Follows **[G11-AZ-C](2026-09-03-g11-az-c-csel-000002-preparation.md)**, which
prepared the candidate against the live written route, and
**[G11-AZ-B](2026-09-03-g11-az-b-croute-0003-production-write.md)**, which
accepted `CROUTE-0003`.

Branch `arch/eng-0005-execution-transition`, HEAD `25d86ad` at the write.

---

## 1. Production CLI output

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CSEL-000002",
  "record_kind": "capability-selection",
  "request_digest": "sha256:ec1cbe8ab042bb3c728eea56d3487ea4eab1e29b114f43e77b1538619d43007f",
  "request_id": "g11azc-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0003",
  "selected_instance_id": "CINST-000003"
}
```

**This output is not the evidence**, and for a selection it is especially not
sufficient: AZ-C §5 established that the request digest cannot witness which
route the selection bound to, because the caller supplies no `route_id`. The
same digest would appear had this resolved against `CROUTE-0002`. Only the
stored record settles it — §2.

## 2. The record, read from production

`/var/lib/kyri/fabric/capability-selections/CSEL-000002.yaml` —
`cschott:cschott 0600`, **1059 bytes**, stored digest
`d344c89729ebbfed61a928881c1933deb235b77df19031469085c49d634a4ccb`.

| governed field | required | stored | |
| --- | --- | --- | --- |
| `selection_id` | `CSEL-000002` | `CSEL-000002` | ✓ |
| `route_id` | `CROUTE-0003` | **`CROUTE-0003`** | ✓ |
| `route_version` | `3` | `3` | ✓ |
| `selected_instance_id` | `CINST-000003` | **`CINST-000003`** | ✓ |
| `reason_category` | `selection` | `selection` | ✓ |
| `excluded_candidates` | `[]` | `[]` | ✓ |
| `considered_candidates` | `[CINST-000003]` | `[CINST-000003]` | ✓ |
| `local_node_identity` | `HOST-0001` | `HOST-0001` | ✓ |

`selection_reason: first eligible candidate in declared order`.
`causal_references: [CROUTE-0003, CINST-000003]`. `approving_authority: null`,
matching `CSEL-000001` — a selection resolves, it does not approve.
`refusal_reason` is absent.

**`reason_category` is `selection`, not `selection-refusal`**, and
`excluded_candidates` is empty. Nothing was considered and rejected. AZ-A §8
showed what the alternative looked like: a `selection-refusal` naming
`CROUTE-0002` with `no-eligible-candidate`, which is the record this ceremony
was sequenced to avoid.

**Request class matches the live route head exactly**, compared field by field
against the stored `CROUTE-0003`:

```
capability_id                CAPDEF-0001   ==  CAPDEF-0001
contract_id                  CCON-0001     ==  CCON-0001
accepted_contract_versions   ['1.0.0']     ==  ['1.0.0']
data_classification          internal      ==  internal
locality                     local-only    ==  local-only
```

## 3. Sequence

```
capability-selection.seq   1  ->  2
```

Advertisement, instance and route sequences unmoved at **4 / 3 / 3**.

Both representations are 2 bytes (`1\n` → `2\n`), so a structural manifest
reports this file as unchanged. Only content accounting sees it — §5.

## 4. Historical selection

`CSEL-000001` after the write:

```
e08a4df4ab758cb0d25609e3cc02b4adca7568ff464b312ac3a2c88b8bbe79bb
```

**Byte-identical** to the value recorded before the write, in AZ-B §6 and again
in the AZ-C preparation. Not mutated, not retired, not annotated.

**Selections form no supersession chain, and this is the model rather than an
omission.** The released `capability-selection` record has no `supersedes`
field at all:

```
selection fields: selection_id, request_class, considered_candidates,
                  excluded_candidates, selection_reason, selected_at,
                  provenance, selected_instance_id, route_id, route_version,
                  refusal_reason, local_node_identity, notes, evidence
```

By contrast the route record does carry `supersedes` / `superseded_by`. So a
head-by-set-difference derivation reports **both** `CSEL-000001` and
`CSEL-000002` as unsuperseded, and that is correct — a selection is a resolution
recorded at an instant, not a standing declaration that a later one replaces.
The accepted semantics hold: route-head movement does not invalidate a
historical selection, and selection eligibility is rechecked at use.

`CSEL-000002` is therefore the **fresh** production selection, not the sole one.

## 5. Mutation accounting

**Structural manifest** — paths, owners, modes, sizes:

```
+ capability-selections/CSEL-000002.yaml   cschott:cschott  600  1059
```

The entire structural delta. The sequence replacement is invisible to it.

**Content manifest** — per-file digests:

```
CREATE   capability-selections/CSEL-000002.yaml   d344c897…4a4ccb
REPLACE  sequences/capability-selection.seq       4355a46b… -> 53c234e5…
REMOVE   (none)
unchanged  23 of 24 pre-existing files
```

**Proved by reconstruction.** The pre-write aggregate was recorded in AZ-B §6
and re-confirmed at the close of the AZ-C preparation as
`ef054d64e48d74b5b4dd1d8d8294f0add7773165ab9c975daf1b375f2ebcd8f5`. Taking the
post-write manifest, removing the `CSEL-000002` line and reverting only the
selection sequence digest to that of `1\n` reproduces:

```
reconstructed pre-write : ef054d64e48d74b5b4dd1d8d8294f0add7773165ab9c975daf1b375f2ebcd8f5
recorded    pre-write   : ef054d64e48d74b5b4dd1d8d8294f0add7773165ab9c975daf1b375f2ebcd8f5   MATCH
```

**Exactly two changes, both intended.** Post-write aggregate:
`7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96`.

Corroborated by modification times — the only Fabric paths touched at the write
are the new record, the selection sequence, and the `capability-selections`
directory entry.

**Surfaces this write did not touch:** `CADV-000004` `965499a3…`, `CINST-000003`
`5b83135d…`, `CROUTE-0003` `18d54f8a…`, `CROUTE-0002` `1a7ed018…`, `CSEL-000001`
`e08a4df4…`, the Trust store, the runtime and the identity authorities — none
modified since before the write.

## 6. The renewed chain

Each head derived by set difference, not assumed:

```
CADV_HEAD    CADV-000004     (of 4; three superseded, one head)
CINST_HEAD   CINST-000003    (of 3; two superseded, one head)
CROUTE_HEAD  CROUTE-0003     (of 3; two superseded, one head)
selection    CSEL-000002     fresh; CSEL-000001 retained, no chain
```

`FABRIC_CHAIN_FRESH = YES`. The chain is renewed end to end:
`CADV-000004 → CINST-000003 → CROUTE-0003 → CSEL-000002`.

**Current eligibility of `CINST-000003`**, re-evaluated at
`2026-09-03T18:13:02-05:00` — after the selection write, not carried forward:

```
eligible : true
unmet    : []
ELIG-1 .. ELIG-12   all met   (12 conditions)
```

## 7. Validation

```
fabric validate   status: reported   findings: []
                  counts 4 / 3 / 3 / 2

trust validate-store   valid: true   problems: []
                       counts  audit 4, authority 1, decision 2, evidence 7, lineage 3, record 2
```

`FABRIC_VALID = YES`, `FABRIC_DEFECTS = 0`, `TRUST_VALID = YES`.

## 8. Authority state

```
HELPER_COMPATIBILITY      compatible   (8 declared, 0 blocking, all current)
COORDINATOR_IDENTITY      PASS   3dec888c…  root:root 0444  cschott/1000
EXECUTION_IDENTITY        PASS   891beeeb…  root:root 0444  kyri-capability/999:987
SUDOERS_CLOSED            YES    (0 non-README files in /etc/sudoers.d)
PRODUCTION_CINV_COUNT     0
PRODUCTION_CRES_COUNT     0
ROOT_AUTHORITY_UNMOUNTED  YES
```

Account↔UID/GID system bindings continue to hold: `cschott` is `uid=1000`,
`kyri-capability` is `uid=999 gid=987`.

**`PRODUCTION_INVOKE_AUTHORISED = NO`.** The Fabric chain is now complete and
current, and that changes nothing about authority. No privileged grant exists,
so the transition from coordinator to worker cannot occur. Readiness and
authority remain separate, and only the grants close that gap.

## 9. Next

**G11-BA** — prepare the two narrow privileged grants (launch and reconcile,
kept as separate independently-withdrawable authorities) and the final
production invoke preflight. Nothing is installed by that preparation, and no
`CINV`/`CRES` is allocated.

Then **G11-BB**, the first controlled production invocation.
