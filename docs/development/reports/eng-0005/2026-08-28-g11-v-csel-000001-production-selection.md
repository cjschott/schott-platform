# ENG-0005 G11-V — CSEL-000001 First Production Governed Selection

- Checkpoint: ENG-0005 G11-V
- Date: 2026-08-28 (local date at report creation; midnight was not crossed)
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `8966aef2a668f24591b0ab4c674b5d7502774701`
- Host: `schai`
- Result: `ACCEPTED`

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `8966aef2a668f24591b0ab4c674b5d7502774701` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-U report present | yes |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Generation 11 runtime | 57 `.py` files, unchanged |
| Root Authority | unmounted |

Inventory matched the required state exactly: CAPDEF 1, CCON 1, CPKG 1, CHOST 1,
CADV 3, CINST 2, CROUTE 2, **CSEL 0**. `capability-selection.seq` **ABSENT**;
`CSEL-000001` destination absent; unique route head `CROUTE-0002` with candidate
list `[CINST-000002]`; `CINST-000002` `admitted`; `CADV-000003` the advertisement
head.

Both manifests captured before any action: structural 28 entries, content 19 files.

## 2. Frozen input and `cmp` proof

| Property | Required | Observed |
|---|---|---|
| Path | `/etc/kyri/fabric/csel-000001.json` | as required |
| Owner | `root:cschott` | `root:cschott` |
| Mode | `0640` | `0640` |
| Size | 591 bytes | 591 bytes |
| SHA-256 | `4dbe0051…a5a7e` | `4dbe005137e16c13156318176280f90bf4216a6195d4756efaf3a8d2da3a5a7e` |
| Parses as JSON | yes | yes |

`cmp` against the byte-identical candidate retained from G11-U: **BYTE-IDENTICAL**.

The body's key set was read back and confirmed to be exactly the eleven fields the
contract accepts:

```
accepted_contract_versions, actor, capability_id, contract_id,
data_classification, evaluated_at, local_node_identity, locality,
provenance, recorded_at, request_id

has approving_authority: False
has operation:           False
```

## 3. Selection contract corrections, preserved

G11-U's source-derived contract was carried forward unchanged. Nothing was silently
corrected.

**No `approving_authority`.** Not a parameter of `select_candidate`; `_write` passes
`approving_authority=None` into `assemble_evidence`. The persisted record therefore
carries `approving_authority: null` — serialised as an explicit null rather than
omitted, which is the released shape for this field.

**No `operation`.** `execute` is not a selection request field. The governed request
class is exactly:

```
capability_id, contract_id, accepted_contract_versions,
data_classification, locality
```

plus the authoritative `local_node_identity` used for locality enforcement.
`execute` exists in `CINST-000002.effective_scope.permitted_operations` but is never
supplied to selection, and the persisted record invents no `operation` field
(verified in section 10).

### 3.1 The mutating path's output vocabulary differs from the rehearsal wrapper

Derived from source **before** judging the result, as instructed.
`cli._governed` emits `SelectionResult.to_dict()`, whose `outcome` is the
`admission` constant, not the internal selection outcome:

```
admission.ACCEPTED = 'accepted'
selection.OUTCOME_CATEGORIES = {'selected': 'selection',
                                'refused': 'selection-refusal',
                                'no-candidate': 'no-candidate'}
cli.ACCEPTING = ('accepted', 'exact-replay')
```

**`outcome: "accepted"` does not mean the selection succeeded.** It means the
governed operation completed and wrote its decision. G11-U's control fixture
demonstrated a refusal returning the same `accepted`. The success/refusal
discriminators are:

- `selected_instance_id` non-null on the result;
- `evidence.reason_category == "selection"` (not `selection-refusal`) on the record;
- `refusal_reason` absent from the record.

All three were checked (sections 9 and 10) rather than reading `accepted` as success.

## 4. Final route resolution

Proved independently of the rehearsal, because G11-T and G11-U established that
rehearsal route metadata is intentionally incomplete.

```
_chain_heads(store, 'capability-route')  = ['CROUTE-0002']
_resolve_route(governed request class)   -> CROUTE-0002
route_version                            = 2
candidate_instances                      = ['CINST-000002']
CINST-000001 is not a candidate          = True
no ambiguity (single match)              = True
request-class match on all five fields   = True
```

`_resolve_route` refuses with `route-ambiguous-for-request-class` when more than one
current route matches; it returned exactly one.

## 5. Final eligibility at the governed instant

`evaluate_eligibility` against `CINST-000002` at `2026-08-28T20:47:35-05:00`:

```
eligible = True   unmet = none   reasons = none
ELIG-1 met   ELIG-2 met   ELIG-3 met   ELIG-4  met
ELIG-5 met   ELIG-6 met   ELIG-7 met   ELIG-8  met
ELIG-9 met   ELIG-10 met  ELIG-11 met  ELIG-12 met
conditions met: 12/12
```

Identical to G11-U, so no stop.

**ELIG-8 stated precisely.** It validates that all four `effective_scope` dimensions
are structurally well-formed, then performs membership checking on exactly one:
`permitted_data_classifications`, confirming `internal`. It does **not** re-check
membership in `permitted_capabilities`, `permitted_operations`, or
`permitted_targets`.

The scope was therefore inspected directly, independent of ELIG-8:

| Dimension | Value | Contains |
|---|---|---|
| `permitted_capabilities` | `['CAPDEF-0001']` | `CAPDEF-0001` ✓ |
| `permitted_operations` | `['execute']` | `execute` ✓ |
| `permitted_data_classifications` | `['internal']` | `internal` ✓ |
| `permitted_targets` | `['HOST-0001']` | `HOST-0001` ✓ |

Locality, enforced by `_locality_permits` rather than by any ELIG condition:

```
CHOST-0001.node_identity_reference = HOST-0001
body.local_node_identity           = HOST-0001
locality                           = local-only
local-only exact equality passes   = True
CHOST-0001 is the current host head = True
```

Existing controls for the dimensions ELIG-8 does not re-check: capability and target
scope were governed during immutable admission (the G11-A2 rule, verified in G11-R);
node identity is enforced by `_locality_permits`; no operation is present in the
request at all. Not patched here — see section 21.

## 6. Final non-mutating rehearsal

```json
{
  "destination": "/var/lib/kyri/fabric/capability-selections/CSEL-000001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "select",
  "outcome": "preflight",
  "predicted_record_id": "CSEL-000001",
  "record_kind": "capability-selection",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21",
  "request_id": "g11u-select-capdef-0001-ccon-0001-internal-local-only-host-0001",
  "selected_instance_id": "CINST-000002",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

Every critical value matched the operator-supplied rehearsal. Absent `route_id`,
`route_version`, and candidate lists were not treated as failures — their absence
under rehearsal is intentional, and route resolution was proved in section 4.

## 7. The rehearsal mutated nothing

```
structural: IDENTICAL
content:    IDENTICAL
CSEL count               = 0
capability-selection.seq = ABSENT
CSEL-000001 destination  = ABSENT
```

## 8. The exact mutating command

Executed once, at `2026-08-28T20:59:49-05:00`:

```bash
python3 -m tools.fabric.cli select \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 \
  --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file csel-000001.json \
  --approved-directory /etc/kyri/fabric
```

Run in the knowledge that it spends `CSEL-000001` whatever the decision.

## 9. Raw mutating result

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CSEL-000001",
  "record_kind": "capability-selection",
  "request_digest": "sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21",
  "request_id": "g11u-select-capdef-0001-ccon-0001-internal-local-only-host-0001",
  "selected_instance_id": "CINST-000002"
}
```

Exit status 0. Judged against the source-derived vocabulary of section 3.1:
`outcome: accepted` establishes only that the decision was written;
`selected_instance_id: CINST-000002` is what establishes it was a **selection** and
not a refusal. Confirmed on the record in section 10.

## 10. Persisted CSEL-000001

```yaml
considered_candidates:
- CINST-000002
evidence:
  actor: primary-platform-operator
  approving_authority: null
  causal_references:
  - CROUTE-0002
  - CINST-000002
  reason_category: selection
  recorded_at: '2026-08-28T20:47:35-05:00'
  request_digest: sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21
  request_id: g11u-select-capdef-0001-ccon-0001-internal-local-only-host-0001
  trust_evidence_references: []
excluded_candidates: []
kind: capability-selection
local_node_identity: HOST-0001
provenance:
  class: declared
  recorded_at: '2026-08-28'
  source: docs/decisions/ADR-0012-distributed-capability-fabric.md
request_class:
  accepted_contract_versions:
  - 1.0.0
  capability_id: CAPDEF-0001
  contract_id: CCON-0001
  data_classification: internal
  locality: local-only
route_id: CROUTE-0002
route_version: 2
schema_version: schott-platform/v1
selected_at: '2026-08-28T20:47:35-05:00'
selected_instance_id: CINST-000002
selection_id: CSEL-000001
selection_reason: first eligible candidate in declared order
```

Field-by-field verification — **26 of 26 pass**:

| Check | Observed |
|---|---|
| `selection_id` | `CSEL-000001` |
| `route_id` | `CROUTE-0002` |
| `route_version` | `2` |
| `request_class.capability_id` | `CAPDEF-0001` |
| `request_class.contract_id` | `CCON-0001` |
| `request_class.accepted_contract_versions` | `['1.0.0']` |
| `request_class.data_classification` | `internal` |
| `request_class.locality` | `local-only` |
| `considered_candidates` contains `CINST-000002` | yes |
| `CINST-000001` **not** considered | correct — not in the list |
| `excluded_candidates` | `[]` |
| `selected_instance_id` | `CINST-000002` |
| `refusal_reason` | **absent from the record entirely** (not null) |
| `selection_reason` | `first eligible candidate in declared order` |
| `selected_at` == body `recorded_at` | `2026-08-28T20:47:35-05:00` |
| `local_node_identity` | `HOST-0001` |
| `provenance` agrees with body | yes |
| `evidence.actor` | `primary-platform-operator` |
| `evidence.approving_authority` | `None` (serialised `null`) |
| `evidence.reason_category` | **`selection`** |
| `evidence.request_id` | matches the reviewed request |
| `evidence.request_digest` | matches the reviewed digest |
| `evidence.causal_references` begins with `CROUTE-0002` | `['CROUTE-0002', 'CINST-000002']` |
| `evidence.causal_references` names the candidate | yes |
| `evidence.trust_evidence_references` | `[]` — the released empty shape |
| **no invented `operation` field** | confirmed; 14 keys, none named `operation` |

Note the asymmetry, reported as observed: `approving_authority` persists as an
explicit `null`, while `refusal_reason` is omitted altogether. Both are released
behaviour for a successful selection.

## 11. CSEL SHA-256

```
path   /var/lib/kyri/fabric/capability-selections/CSEL-000001.yaml
owner  cschott:cschott   mode 0600   size 1045
sha256 e08a4df4ab758cb0d25609e3cc02b4adca7568ff464b312ac3a2c88b8bbe79bb
```

**A correction to G11-U.** That report stated the fixture record's digest "will not
equal the eventual production record". It does — the production record is
byte-identical to the G11-U fixture record, `e08a4df4…79bb`. The prediction was
wrong: a selection record's content is determined entirely by the decision body, the
resolved route, and the chosen candidate, all of which were identical between the
fixture and production. The fixture's differing upstream provenance never reaches
the selection record. Correcting it here because a reviewer comparing the two
reports would otherwise treat a genuine match as an anomaly.

## 12. Route, version, and selected instance

```
route_id             = CROUTE-0002
route_version        = 2
selected_instance_id = CINST-000002
```

Attribution is consistent with the independent route resolution of section 4: the
record names the route that `_resolve_route` returns for this request class, at the
version that route carries.

## 13. Request digest

```
sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21
```

One value across four independent computations: the G11-U production rehearsal, the
G11-U independent fixture write, the G11-V final rehearsal, and this production
write — and it is the value persisted in `evidence.request_digest`.

## 14. Evidence proof

```
actor                      primary-platform-operator
approving_authority        null              (selection accepts none)
reason_category            selection         (not selection-refusal, not no-candidate)
recorded_at                2026-08-28T20:47:35-05:00
request_id                 g11u-select-capdef-0001-ccon-0001-internal-local-only-host-0001
request_digest             sha256:507b29db…5c21
causal_references          ['CROUTE-0002', 'CINST-000002']
trust_evidence_references  []
```

`causal_references` follows `_write`'s construction — the route identity first, then
every considered candidate in declared order. `trust_evidence_references` is empty
because selection cites no Trust record directly; standing reached the decision
through eligibility, which asks C3 itself.

## 15. First-selection sequence creation

```
before  capability-selection.seq  ABSENT
after   /var/lib/kyri/fabric/sequences/capability-selection.seq
        owner cschott:cschott  mode 0600  size 2
        content (od): 1 \n
        is exactly "1\n": YES
CSEL count = 1
```

This is a **new file**, not an in-place replacement. G11-U proved in fixtures that
both a successful and a refused first selection create it at `1\n`; production
confirms the successful case.

## 16. Exact mutation accounting — two additions

Structural manifest, before → after:

```
> f 600 1000:1000 1045 ./capability-selections/CSEL-000001.yaml
> f 600 1000:1000    2 ./sequences/capability-selection.seq
```

Content manifest, before → after:

```
> e08a4df4…79bb  capability-selections/CSEL-000001.yaml
> 4355a46b…d865  sequences/capability-selection.seq
```

| Requirement | Observed |
|---|---|
| two additions | yes |
| zero replacements | yes |
| zero removals | yes |
| zero modifications to pre-existing records | yes |

Unlike G11-P, G11-R, and G11-T — where the sequence file already existed and its
equal-length replacement was invisible to the structural manifest — **both changes
appear structurally here**, exactly as G11-U predicted. The content manifest shows
two additions and no replacement lines.

## 17. No pre-existing record changed

Every prior governed record and every neighbouring authority is byte-identical
before and after:

| Object | Change |
|---|---|
| `CROUTE-0001` | none |
| `CROUTE-0002` | none |
| `CINST-000001` | none |
| `CINST-000002` | none |
| `CADV-000003` | none |
| Trust authority | none |
| Artifact authority | none |
| Platform Evidence | none |
| Installed runtime (57 `.py`) | none |

The frozen operator input is also unchanged: `root:cschott 0640`, 591 bytes,
`4dbe0051…a5a7e`.

## 18. Validation after the selection

| Check | Observed |
|---|---|
| Fabric inspection | `reported`, **zero defects** |
| Trust store | `valid: True`, **zero problems** |
| Generation 11 runtime | 57 `.py` files, digest unchanged |
| Root Authority | unmounted |
| Route head | still `CROUTE-0002` |
| `CINST-000002` | still `admitted` |
| Advertisement head | still `CADV-000003` |

A selection changes no topology; it records a decision about one.

## 19. The complete governed decision chain

The first end-to-end governed chain in the platform's history is now closed and
persisted:

```
CADV-000003   observed 2026-08-28T16:19:19-05:00, valid_until 2026-08-30T16:19:19-05:00
    ↓         a host's self-report, renewed under supersession
CINST-000002  advertisement_id = CADV-000003, admitted_until 2026-08-30T16:19:19-05:00
    ↓         a human admission bounded by the advertisement it depends on
CROUTE-0002   candidate_instances = ['CINST-000002'], route_version 2
    ↓         a human policy naming which bindings may serve the request class
CSEL-000001   route_id = CROUTE-0002, selected_instance_id = CINST-000002
              reason: first eligible candidate in declared order
```

Every link was independently verified from the records rather than inferred:
`CINST-000002.advertisement_id` names `CADV-000003`;
`CROUTE-0002.candidate_instances` names `CINST-000002`;
`CSEL-000001.route_id` names `CROUTE-0002` and its
`selected_instance_id` names `CINST-000002`.

**Advertise → admit → route → select is complete.**

## 20. Route-head hardening gate

`NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING = YES`, carried forward unchanged.

No `CROUTE-0003` or other route successor may be prepared or written until the
G11-K non-head-predecessor gap receives a dedicated RED-first correction and
verification. Production holds two routes, so a future `create_route` naming
`supersedes: CROUTE-0001` would be accepted and would fork the chain into a state
`_resolve_route` refuses as `route-ambiguous-for-request-class`. Not patched here.

## 21. ⚠ Mandatory pre-invoke scope/operation ruling

`PRE_INVOKE_SCOPE_OPERATION_RULING_REQUIRED = YES`.
`STAGE_INVOKE_AUTHORISED = NO`.

The selected capability was **not** staged and **not** invoked, and must not be
until a dedicated checkpoint resolves the following. Stated as questions with what
this checkpoint established, not as answers:

1. **Should a governed operation such as `execute` become part of the
   selection/request class?** Today it is not. `CSEL-000001` records that
   `CINST-000002` may serve a request class, and says nothing about which operation
   will be performed against it.
2. **Should selection-time scope validation re-check membership of
   `permitted_capabilities`, `permitted_operations`, and `permitted_targets` in
   addition to classification?** ELIG-8 currently checks membership on
   classification only; the other three are validated for well-formedness alone
   (section 5).
3. **Is admission-time enforcement plus immutable records intentionally sufficient
   for capability and target, or should selection independently revalidate them?**
   The records are immutable and admission did enforce both, so revalidation would
   re-derive a settled fact — but nothing in the source states that this is the
   reasoning, and the dimensions are silently unused rather than documented as
   deliberately delegated.
4. **If operation remains absent from selection, where is the execution operation
   authorised at the invoke boundary?** No component examined in G11-C, G11-U, or
   G11-V authorises an operation. `permitted_operations = ['execute']` sits on the
   instance and is read by nothing.
5. **What RED tests are required before changing released behaviour?** At minimum:
   a test pinning current ELIG-8 semantics so any change is deliberate; a test that
   an instance whose scope omits the asked capability is or is not excluded; and, if
   an operation field is added, tests that an unpermitted operation is refused and
   that existing bodies without the field are handled explicitly rather than
   defaulting.

Question 4 is the one that matters most for safety: an invoke boundary that does not
consult `permitted_operations` would execute without any component having checked
the operation against the governed scope. This was **not** resolved by making code
changes here.

## 22. Actions not performed

- Production `select` executed **once** only; no second mutating call of any kind.
- No `CSEL-000002`.
- No capability staged; no capability invoked.
- No route created; no `CROUTE-0003`; `CROUTE-0001` and `CROUTE-0002` untouched.
- `CINST-000001` not withdrawn, retired, or modified.
- No `CINST-000003`, no `CADV-000004`.
- No patch to route-head enforcement, scope semantics, replay behaviour, or
  withdrawn-binding routing; no `operation` added to selection.
- No mutation of Trust, Artifact authority, or Platform Evidence.
- No runtime reinstall; no sudoers modification; no Root Authority mount.
- No ENG-0006 work; no TrustGateway cutover.
- No source or test change; no implementation commit.
- Replay was **not** exercised — no read-only replay mechanism was invoked, and the
  successful first decision is sufficient for G11-V.

## Appendix A — commands executed

```bash
# Mandatory pre-write gates
git rev-parse HEAD; git status --porcelain
stat -c '%U:%G %a %s' /etc/kyri/fabric/csel-000001.json; sha256sum ...
cmp /etc/kyri/fabric/csel-000001.json <retained G11-U candidate>
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# Output vocabulary derived from source BEFORE judging the result
#   cli._governed -> SelectionResult.to_dict(); admission.ACCEPTED = 'accepted'
#   selection.OUTCOME_CATEGORIES; cli.ACCEPTING

# Final gates (read-only)
#   selection._chain_heads / selection._resolve_route / selection._locality_permits
#   eligibility.evaluate_eligibility at 2026-08-28T20:47:35-05:00

python3 -m tools.fabric.cli select --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file csel-000001.json --approved-directory /etc/kyri/fabric

# THE AUTHORISED SELECTION  (run once)
python3 -m tools.fabric.cli select \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file csel-000001.json --approved-directory /etc/kyri/fabric

# Post-selection verification: both manifests diffed, authority digests,
# full record read-back, sequence content via od, chain traversal, validation
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001  kyri-execution-boundary-verification
CCON-0001    1.0.0, computational (routable), deterministic
CPKG-0001    1.0.0
CHOST-0001   node identity HOST-0001, on-premises, internal, in-service
CADV-000001 → CADV-000002 → CADV-000003   head CADV-000003, valid_until 2026-08-30T16:19:19-05:00
CINST-000001 admitted, adv CADV-000002, ineligible from 2026-08-29T09:24:51-05:00, not routed
CINST-000002 admitted, adv CADV-000003, until 2026-08-30T16:19:19-05:00, ELIG 12/12
CROUTE-0001 → CROUTE-0002                 head CROUTE-0002, candidates ['CINST-000002']
CSEL-000001  selection, route CROUTE-0002 v2, selected CINST-000002,
             no exclusions, sha256 e08a4df4…79bb
capability-selection.seq  1
```
