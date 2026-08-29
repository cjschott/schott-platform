# ENG-0005 G11-R — CINST-000002 Production Admission Write and Independent Verification

- Checkpoint: ENG-0005 G11-R
- Date: 2026-08-28
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `afe5b17c1cd7c1222aa2cd24b2707e1c7d540861`
- Host: `schai`
- Result: `SUCCESS`

## 1. Objective and outcome

Execute the authorised production `admit-instance` write of `CINST-000002` from the
frozen operator input, then verify the result independently of the tool that
produced it.

The write was executed **once** and was accepted. `CINST-000002` exists, is
`admitted`, supersedes `CINST-000001`, is bound to `CADV-000003`, and closes at
exactly `CADV-000003.valid_until`.

Every mandatory pre-write gate passed before the command ran. The live preflight
returned the same `request_digest` recorded in G11-Q, so the body that was written
is provably the body that was rehearsed:

```
sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f
```

One finding requires reviewer attention and is stated in full in section 15: the
supersession **does not** move the route. `CROUTE-0001` still names `CINST-000001`
alone, and `CINST-000001` lapses at `2026-08-29T13:46:27-05:00`. From that instant
the capability is unroutable, even though `CINST-000002` remains admitted for
another day.

## 2. Starting authority and production state

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `afe5b17c1cd7c1222aa2cd24b2707e1c7d540861` — matched the expected authority |
| Worktree | clean (no modified, staged, or untracked paths) |
| HEAD published | contained in `origin/arch/eng-0005-execution-transition` |

Production inventory immediately before the write:

| Kind | Count |
|---|---|
| capability-definitions | 1 |
| capability-contracts | 1 |
| capability-packages | 1 |
| capability-hosts | 1 |
| capability-advertisements | 3 |
| capability-instances | **1** |
| capability-routes | 1 |
| capability-selections | 0 |

`capability-instance.seq = 1`. The destination
`/var/lib/kyri/fabric/capability-instances/CINST-000002.yaml` was **absent**.

Plane health before the write: fabric inspection `reported`, zero defects; Trust
store `valid: True`, zero problems; installed runtime 57 `.py` files; Root
Authority **unmounted**.

## 3. Frozen input verification

| Property | Required | Observed |
|---|---|---|
| Path | `/etc/kyri/fabric/cinst-000002.json` | as required |
| Owner | `root:cschott` | `root:cschott` |
| Mode | `0640` | `0640` |
| Size | 1267 bytes | 1267 bytes |
| SHA-256 | `e0ecb548…925d` | `e0ecb54805c072c6d2c25b2887ab33b1af4214be3b2e63889c14c0b6cf43925d` |
| Parses as JSON | yes | yes |
| Copies in the approved directory | exactly 1 | exactly 1 |

The frozen file was additionally compared byte-for-byte with the candidate retained
in the G11-Q scratchpad: **identical**. The operator froze the rehearsed body and
nothing else.

## 4. Mandatory final pre-write check — both manifests

Per the G11-P finding that an equal-length sequence replacement is invisible to a
structural manifest, **two** manifests were captured before the write:

- structural/metadata, `%y %m %U:%G %s %p` — 26 entries
- content, per-path SHA-256 — 17 files

Both were re-captured after the live preflight and before the write, and compared:

```
structural: IDENTICAL
content:    IDENTICAL
capability-instance.seq = 1
```

The preflight is read-only in fact, not merely by declaration.

## 5. Final Trust re-evaluation

Re-evaluated from the store at the body's governed instant — **not** at wall clock,
and **not** from any cached G11-Q verdict.

```
governed evaluated_at = 2026-08-28T19:29:09-05:00
wall clock at check   = 2026-08-28T19:48:56-05:00   (informational only)
CHOST-0001.node_identity_reference = HOST-0001
```

Per the G11-A2 rule, the permitted target is compared against the **node identity**
`HOST-0001`, not against `CHOST-0001`.

| | fabric-node | capability-package |
|---|---|---|
| Trust record | `TREC-000001` | `TREC-000002` |
| Subject | `HOST-0001` | `CPKG-0001` |
| Domain (from the record) | `fabric-node` | `capability-package` |
| Decision / lineage | `TDEC-000001` / `TLIN-000002` | `TDEC-000002` / `TLIN-000003` |
| Status / standing | `verified` / `trusted` | `verified` / `trusted` |
| Still the subject's current record | yes | yes |
| `expires_at` | none | none |
| Scope | `TSCOPE-000001` | `TSCOPE-000002` |
| Scope validity | open-ended → instant in window | open-ended → instant in window |
| `permitted_capabilities` | `['CAPDEF-0001']` | `['CAPDEF-0001']` |
| `permitted_operations` | `['execute']` | `['execute']` |
| `permitted_data_classifications` | `['internal']` | `['internal']` |
| `permitted_targets` | `['HOST-0001']` | `['HOST-0001']` |
| `HOST-0001` in targets | **yes** | **yes** |
| `CHOST-0001` in targets | no — deliberately not the test | no — deliberately not the test |
| Requested `admission_scope` ⊆ Trust scope | yes | yes |

Both standings are identical to G11-Q. No divergence, so no stop.

One correction to my own method, recorded because it affected the first attempt:
`tools.trust.evaluator` exposes no `current_standing`, and the scope is embedded in
the `record` kind rather than reachable through a `decision` identifier. The
verdict above was reached through the released adapter
`tools.fabric.trust_adapter.verify_trust_record` plus the record's own embedded
scope — the same route the Fabric itself uses.

## 6. Dependency preconditions

| Requirement | Observed |
|---|---|
| `CINST-000001` resolves | yes |
| `CINST-000001.lifecycle_state` | `admitted` |
| `CINST-000001` has no successor | true |
| `advertisement_head(CADV-000003)` | `CADV-000003` |
| Body's `advertisement_id` | `CADV-000003` |
| Body's advertisement is the current head (R16) | **yes** |
| `CADV-000003.valid_until` | `2026-08-30T16:19:19-05:00` |
| Body `admitted_until` | `2026-08-30T16:19:19-05:00` |
| Dependency bound holds (R17 tail = zero) | **yes** |

## 7. Final approved-boundary preflight

```json
{
  "destination": "/var/lib/kyri/fabric/capability-instances/CINST-000002.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "admit-instance",
  "outcome": "preflight",
  "predicted_record_id": "CINST-000002",
  "record_kind": "capability-instance",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f",
  "request_id": "g11q-admit-instance-cpkg-0001-chost-0001-cadv-000003-supersedes-cinst-000001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

The digest matches the G11-Q fixture rehearsal, the G11-Q independent fixture
write, and the G11-Q live production preflight. Four independent computations,
one value.

## 8. The production write

Executed exactly once:

```
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json --approved-directory /etc/kyri/fabric
```

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CINST-000002",
  "record_kind": "capability-instance",
  "request_digest": "sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f",
  "request_id": "g11q-admit-instance-cpkg-0001-chost-0001-cadv-000003-supersedes-cinst-000001"
}
```

Exit status 0. The write digest equals the preflight digest: what was judged is
what was committed.

## 9. The persisted record

```
path   /var/lib/kyri/fabric/capability-instances/CINST-000002.yaml
owner  cschott:cschott   mode 0600   size 1406
sha256 5cfcf01e778856889c6aaa0838f986a0c43878033b29da1fd198be3070e3f719
```

Field-by-field agreement with the frozen body:

| Field | Stored | Body | |
|---|---|---|---|
| `capability_id` | `CAPDEF-0001` | `CAPDEF-0001` | OK |
| `capability_package_id` | `CPKG-0001` | `CPKG-0001` | OK |
| `capability_host_id` | `CHOST-0001` | `CHOST-0001` | OK |
| `contract_id` | `CCON-0001` | `CCON-0001` | OK |
| `advertisement_id` | `CADV-000003` | `CADV-000003` | OK |
| `supersedes` | `CINST-000001` | `CINST-000001` | OK |
| `admitted_at` | `2026-08-28T19:29:09-05:00` | same | OK |
| `admitted_until` | `2026-08-30T16:19:19-05:00` | same | OK |
| `host_trust_record_id` | `TREC-000001` | `TREC-000001` | OK |
| `package_trust_record_id` | `TREC-000002` | `TREC-000002` | OK |
| `satisfied_contract_versions` | `['1.0.0']` | `['1.0.0']` | OK |
| `verified_resource_profile` | `{architecture: x86-64}` | same | OK |
| `admission_scope` → `effective_scope` | see below | see below | OK |
| `evidence.actor` | `primary-platform-operator` | same | OK |
| `evidence.approving_authority` | `primary-platform-operator` | same | OK |

Governed fields not supplied by the body:

| Field | Stored |
|---|---|
| `instance_id` | `CINST-000002` |
| `kind` | `capability-instance` |
| `schema_version` | `schott-platform/v1` |
| `lifecycle_state` | `admitted` |
| `admission_decision_id` | `eng-0005-cinst-000002-admission` — the R18 ceremony name, **not** a TDEC identifier |
| `evidence.reason_category` | `supersession` |
| `evidence.recorded_at` | `2026-08-28T19:29:09-05:00` |
| `evidence.request_digest` | matches the write digest |
| `evidence.causal_references` | `CAPDEF-0001, CCON-0001, CPKG-0001, CHOST-0001, CADV-000003, CINST-000001` |
| `evidence.trust_evidence_references` | `TREC-000002, TREC-000001` |

**The requested `admission_scope` is stored under the governed name
`effective_scope`.** The stored record carries no `admission_scope` key. Contents
are equal on all four dimensions:

```
permitted_capabilities          ['CAPDEF-0001']
permitted_data_classifications  ['internal']
permitted_operations            ['execute']
permitted_targets               ['HOST-0001']
```

My first comparison pass reported this field as disagreeing. That was my key name,
not the record — the operation renames the requested scope to the effective scope
on commit, exactly as `CINST-000001` also shows. The two instance records differ in
key set by `supersedes` alone.

## 10. Supersession semantics

| Property | Observed |
|---|---|
| `CINST-000002.supersedes` | `CINST-000001` |
| `CINST-000002.evidence.reason_category` | `supersession` |
| Predecessor cited in causal references | yes |
| `CINST-000001.superseded_by` present | **no** — the derived legacy backlink is written by nothing |
| `CINST-000001` bytes | unchanged (proved by content manifest) |

Binding roots, read from the store:

```
LIFECYCLE_CATEGORIES = ('withdrawal', 'retirement')     supersession is NOT one

_binding_root(CINST-000001) = CINST-000001   reason_category='instance-admission'
_binding_root(CINST-000002) = CINST-000002   reason_category='supersession'
```

`CINST-000002` **begins a new binding**. It does not continue `CINST-000001`'s.
This is the doctrine established in G11-F and G11-Q behaving as ruled, now
confirmed on committed production records rather than in a fixture.

## 11. ⚠ CINST-000002 DOES NOT RENEW CINST-000001

Stated prominently because the parallel claim had to be made for `CADV-000003` in
G11-P, and the same misreading is available here.

| | Observed |
|---|---|
| `CINST-000001.lifecycle_state` | `admitted` — **unchanged**, not withdrawn, not retired |
| `CINST-000001.admitted_until` | `2026-08-29T13:46:27-05:00` — **not extended** |
| `CINST-000001.superseded_by` | absent |
| `CINST-000001` key set | unchanged |

Both instances are simultaneously `admitted` until `2026-08-29T13:46:27-05:00`.
After that instant `CINST-000001` lapses on its own original terms and
`CINST-000002` continues alone until `2026-08-30T16:19:19-05:00`. Supersession
stated the succession forward; it did not reach back and alter the predecessor.

## 12. Chain and head verification

```
advertisement_head(CADV-000001) = CADV-000003
advertisement_head(CADV-000002) = CADV-000003
advertisement_head(CADV-000003) = CADV-000003
```

An instance write does not move an advertisement head. The dependency bound holds
on the committed record:

```
CADV-000003.valid_until      = 2026-08-30T16:19:19-05:00
CINST-000002.admitted_until  = 2026-08-30T16:19:19-05:00
R17 tail = ZERO
```

There is no interval in which `CINST-000002` is admitted while its advertisement is
stale.

## 13. Exact mutation accounting

Structural manifest, before → after — **one addition, zero removals, zero
modifications**:

```
> f 600 1000:1000 1406 ./capability-instances/CINST-000002.yaml
```

Content manifest, before → after — **one addition and one replacement**:

```
> 5cfcf01e…f719  capability-instances/CINST-000002.yaml
< 4355a46b…d865  sequences/capability-instance.seq
> 53c234e5…d3c3  sequences/capability-instance.seq
```

The sequence file is the equal-length replacement (`1` → `2`) that the structural
manifest cannot show. This is precisely the class of change G11-P proved invisible
to metadata alone, and it is why both manifests were taken.

Nothing else moved. Whole-authority digests before and after are identical:

| Authority | Digest | Change |
|---|---|---|
| Trust | `cffd362c…bc39` | none |
| Artifact | `30732e2c…257f` | none |
| Evidence | `227abde8…984b` | none |
| Installed runtime (`/usr/lib/kyri/python`, 57 `.py`) | `80f9dee2…107b5f` | none |
| `CINST-000001.yaml` | `92eba1c3…e729` | none |
| `CADV-000003.yaml` | `f2b48c2e…116d` | none |
| `CROUTE-0001.yaml` | `6bf6aa0f…8707` | none |

The frozen operator input is also unchanged: `root:cschott 0640`, 1267 bytes,
`e0ecb548…925d`.

## 14. Inventory, sequence, and validation after the write

| Kind | Before | After |
|---|---|---|
| capability-instances | 1 | **2** |
| capability-advertisements | 3 | 3 |
| capability-routes | 1 | 1 |
| capability-selections | 0 | 0 |
| all others | unchanged | unchanged |

`capability-instance.seq`: 1 → **2**. Total objects under
`/var/lib/kyri/fabric`: 27.

- fabric inspection: `reported`, **zero defects**
- Trust store: `valid: True`, **zero problems**
- installed runtime: 57 `.py` files (unchanged)

Replay of the identical frozen input was checked **read-only**, via `--preflight`
— no second write was attempted:

```
rehearsal_outcome  : refused
rehearsal_reason   : supersedes-already-superseded
would_accept       : false
predicted_record_id: CINST-000003
```

Worth the reviewer's note: the replay is blocked by **supersession-chain
enforcement**, not by request-digest replay detection. The digest is unchanged
across both invocations and the plane does not treat that as disqualifying on its
own. The protection here is structural.

## 15. ⚠ Finding — the supersession does not move the route

`CROUTE-0001`, read after the write:

```
route_id            CROUTE-0001
capability_id       CAPDEF-0001
contract_id         CCON-0001
locality            local-only
candidate_instances ['CINST-000001']
```

`CINST-000002` is admitted but **not routable** — no route names it. `CROUTE-0001`
still names only `CINST-000001`, which is now the superseded predecessor.

The consequence is dated. `tools/fabric/eligibility.py` marks a candidate UNMET with
`admission-window-expired` once the evaluation instant reaches `admitted_until`:

```python
if instant >= expires:
    return ConditionResult("", UNMET, REASON_ADMISSION_EXPIRED)
```

Therefore:

| Instant | State |
|---|---|
| now → `2026-08-29T13:46:27-05:00` | `CROUTE-0001` resolves; `CINST-000001` still eligible |
| **`2026-08-29T13:46:27-05:00`** | `CINST-000001` lapses; `CROUTE-0001`'s only candidate becomes ineligible |
| → `2026-08-30T16:19:19-05:00` | **capability unroutable** for ~26.5 hours despite `CINST-000002` being admitted |

This is not a defect introduced by this write, and it was not in scope to repair
here. It is the already-recorded route-head enforcement gap becoming operationally
concrete: routes bind instance identities, supersession does not update them, and
nothing refuses a route whose bound instance has been superseded.

I did not run a live selection preflight to demonstrate the refusal directly,
because `select --preflight` requires a decision body inside the root-owned
approved directory `/etc/kyri/fabric`, which needs operator action. The finding
above is read from the released eligibility source and the committed records, not
from an executed selection.

**Recommendation for the reviewer**: a `CROUTE-0002` naming `CINST-000002` is
required before `2026-08-29T13:46:27-05:00` if the capability is to remain
routable. That decision is the reviewer's; I have not prepared it.

## 16. Clock state

| Value | Instant |
|---|---|
| Wall clock at the write | `2026-08-28T19:45`–`19:52-05:00` |
| Governed `recorded_at` / `evaluated_at` / `admitted_at` | `2026-08-28T19:29:09-05:00` |
| `CINST-000001` closes | `2026-08-29T13:46:27-05:00` |
| `CINST-000002` closes | `2026-08-30T16:19:19-05:00` |
| `CADV-000003` closes | `2026-08-30T16:19:19-05:00` |

The governed instants are the frozen ones from G11-Q. Wall clock advanced roughly
16–23 minutes between the freeze and the write; this is not a validation input and
was not treated as one.

## 17. Assumptions

- The operator's freeze is authoritative and complete; it was verified by digest,
  ownership, mode, size, and byte comparison rather than assumed.
- `admission_scope` → `effective_scope` is a governed rename, not a discrepancy.
  Confirmed by the same shape in `CINST-000001`, which predates this checkpoint.
- Trust scopes with `validity_start`/`validity_end` of `null` are open-ended and
  contain every instant. This is how the released adapter treats them.

## 18. Deviations

None. The write command was executed verbatim as authorised, once.

## 19. Actions NOT performed

- No second write, and no retry with modified input.
- No `CINST-000003`, no `CROUTE-0002`, no `CADV-000004`, no `CSEL` record.
- No repair of the route-head enforcement gap or the withdrawn-binding routing gap.
- No mutation of Trust, Artifact authority, or Platform Evidence.
- No reinstallation of Generation 11 and no modification of the installed runtime.
- No sudoers modification; no Root Authority mount (it remained unmounted).
- No package staged, no capability invoked.
- No ENG-0006 work; no TrustGateway cutover.
- No writes into `/etc/kyri/fabric`.

## 20. Known risks

- **The dated routability cliff in section 15** is the material one.
- Both admitted instances share one host, one package, and one advertisement. There
  is no second candidate; any single-record problem is a total outage.
- The 48-hour `CADV-000003` window remains ceremony policy only and must not be
  inferred as a platform default.

## 21. Carried-forward items

| Item | Status |
|---|---|
| Route predecessor/head enforcement | still open — mandatory before `CROUTE-0003` or ENG-0005 closure, whichever comes first; section 15 raises its urgency |
| Withdrawn-binding route admission | still open — compensated by selection's `instance-not-admitted` |
| Preflight coverage: `withdraw-subject`, `refresh-subject`, `withdraw-instance`, `retire-instance` | four operations still uncovered |
| Artifact authority digest discrepancy vs G11-A/B/C records | unresolved; digest `30732e2c…257f` observed again here, bytes provably unmoved |
| Two installed execution helper modules lagging repo source | unresolved; a future generation's matrix decision |

## 22. Questions for the reviewer

1. Should a `CROUTE-0002` naming `CINST-000002` be prepared before
   `2026-08-29T13:46:27-05:00`, or is the routability gap accepted for this
   bootstrap? This is time-bounded and needs an answer today.
2. Given section 15, does route-head enforcement now move ahead of `CROUTE-0003` —
   the reviewer previously ruled `ROUTE_HEAD_HARDENING_BEFORE_CROUTE_0002 = NO`,
   and this write is the first evidence of the gap having a dated consequence.
3. Should replay protection be digest-based rather than relying on
   supersession-chain structure? Today an identical body is refused only because
   the predecessor is already superseded.
4. Is `CINST-000001` to be left to lapse on its own terms, or explicitly withdrawn?

## Appendix A — commands executed

```bash
# Pre-write checks
git rev-parse HEAD; git status --porcelain
git branch -r --contains afe5b17c1cd7c1222aa2cd24b2707e1c7d540861
stat -c '%U:%G %a %s' /etc/kyri/fabric/cinst-000002.json
sha256sum /etc/kyri/fabric/cinst-000002.json
cmp /etc/kyri/fabric/cinst-000002.json <retained G11-Q candidate>

# Both manifests, before
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )

# Trust re-evaluation at the governed instant (read-only)
#   tools.fabric.trust_adapter.verify_trust_record(ts, TREC-00000{1,2},
#       evaluated_at=2026-08-28T19:29:09-05:00, expected_subject_type=...)

# Final approved-boundary preflight
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json --approved-directory /etc/kyri/fabric --preflight

# THE AUTHORISED WRITE  (run once)
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json --approved-directory /etc/kyri/fabric

# Post-write verification
# both manifests again, diffed; authority digests; record read-back;
# tools.fabric.inspection.inspect_records
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
# read-only replay check via --preflight
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001  kyri-execution-boundary-verification
CCON-0001    1.0.0, computational, deterministic
CPKG-0001    1.0.0
CHOST-0001   node identity HOST-0001
CADV-000001 → CADV-000002 → CADV-000003   head CADV-000003, valid_until 2026-08-30T16:19:19-05:00
CINST-000001 admitted, closes 2026-08-29T13:46:27-05:00   binding root CINST-000001
CINST-000002 admitted, closes 2026-08-30T16:19:19-05:00   binding root CINST-000002, supersedes CINST-000001
CROUTE-0001  local-only, candidate_instances ['CINST-000001']
CSEL         none
```
