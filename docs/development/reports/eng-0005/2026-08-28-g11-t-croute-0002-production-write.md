# ENG-0005 G11-T — CROUTE-0002 Production Cutover Write and Independent Selection Verification

- Checkpoint: ENG-0005 G11-T
- Date: 2026-08-28 (local date at report creation; midnight was not crossed)
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `100df12ef56203f9dfe82c770019b8e0e5c8d3e5`
- Host: `schai`
- Result: `ACCEPTED`

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `100df12ef56203f9dfe82c770019b8e0e5c8d3e5` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-S report present | yes |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Generation 11 runtime | 57 `.py` files, unchanged |
| Root Authority | unmounted |

Pre-write inventory: CADV 3, CINST 2, CROUTE 1, CSEL 0;
`capability-route.seq = 1`; `CROUTE-0002.yaml` absent.

Both manifests captured before any action: structural 27 entries, content 18 files.

## 2. Frozen input and `cmp` proof

| Property | Required | Observed |
|---|---|---|
| Path | `/etc/kyri/fabric/croute-0002.json` | as required |
| Owner | `root:cschott` | `root:cschott` |
| Mode | `0640` | `0640` |
| Size | 676 bytes | 676 bytes |
| SHA-256 | `dcbdae8c…02c5e` | `dcbdae8c274f3fffbd3f67c31a72f88be290aa74b2377d34ca4c22cd5b702c5e` |
| Parses as JSON | yes | yes |
| Copies named `croute-0002.json` | exactly 1 | exactly 1 |

`cmp` against the byte-identical candidate retained from G11-S: **BYTE-IDENTICAL**.
The operator froze the reviewed bytes and nothing else.

## 3. The corrected routability deadline

G11-S established that the operative cliff is `2026-08-29T09:24:51-05:00`
(`CADV-000002.valid_until`, ELIG-6 `advertisement-not-fresh`), not the later
`2026-08-29T13:46:27-05:00` (`CINST-000001.admitted_until`, ELIG-7
`admission-window-expired`). The brief adopts the corrected instant.

At the moment of the final pre-write check:

```
now                = 2026-08-28T20:18:53-05:00
routability cliff  = 2026-08-29T09:24:51-05:00
time remaining     = 13:05:58
BEFORE the cliff   = True
```

The cliff was independently re-proved after the write by projecting eligibility to
the exact instant (section 15).

## 4. Final route-head proof, immediately before the write

**[1] Released helper** — `selection._chain_heads(store, "capability-route")`:

```
['CROUTE-0001']
```

**[2] Raw traversal / set difference over `supersedes`**:

```
raw ids                      = ['CROUTE-0001']
raw superseded set           = []
raw heads = ids - superseded = ['CROUTE-0001']
```

| Required condition | Observed |
|---|---|
| route IDs == `['CROUTE-0001']` | true |
| unique head == `CROUTE-0001` | true |
| no route supersedes `CROUTE-0001` | true |
| `CROUTE-0001` has no predecessor | true |
| `CROUTE-0001` still names only `CINST-000001` | `['CINST-000001']` |

Candidate preconditions, also re-proved immediately before the write:

```
CINST-000002 exists                : True
CINST-000002.lifecycle_state       : 'admitted'
_binding_root(CINST-000002)        : CINST-000002
CINST-000002.advertisement_id      : CADV-000003
advertisement_head(CADV-000003)    : CADV-000003
```

Because `CROUTE-0001` was the sole record of its kind, it was necessarily the head,
and the G11-K non-head-predecessor defect was unreachable for this write.

## 5. Final approved-boundary preflight

```json
{
  "destination": "/var/lib/kyri/fabric/capability-routes/CROUTE-0002.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "create-route",
  "outcome": "preflight",
  "predicted_record_id": "CROUTE-0002",
  "record_kind": "capability-route",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:a7abf7966d4c82510c0f4cc26dfffd67e0d89eb560fda9e1c0ef3a13bbcd52b6",
  "request_id": "g11s-create-route-capdef-0001-ccon-0001-cinst-000002-supersedes-croute-0001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

Every required value matched the reviewed preflight exactly. Afterwards:

```
structural: IDENTICAL
content:    IDENTICAL
capability-route.seq = 1
CROUTE count = 1
```

The preflight is read-only in fact, not merely by declaration.

## 6. The production write

Executed exactly once, at `2026-08-28T20:19:35-05:00`:

```
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0002.json --approved-directory /etc/kyri/fabric
```

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CROUTE-0002",
  "record_kind": "capability-route",
  "request_digest": "sha256:a7abf7966d4c82510c0f4cc26dfffd67e0d89eb560fda9e1c0ef3a13bbcd52b6",
  "request_id": "g11s-create-route-capdef-0001-ccon-0001-cinst-000002-supersedes-croute-0001"
}
```

Exit status 0. Outcome, reason, identity, and digest all match the authorised
expectation. The digest is the same value computed in the G11-S fixture rehearsal,
the G11-S independent fixture write, the G11-S live preflight, and the G11-T final
preflight — five independent computations, one value.

## 7. CROUTE-0002 persisted content

```yaml
accepted_contract_versions:
- 1.0.0
candidate_instances:
- CINST-000002
capability_id: CAPDEF-0001
contract_id: CCON-0001
data_classification: internal
evidence:
  actor: primary-platform-operator
  approving_authority: primary-platform-operator
  causal_references:
  - CAPDEF-0001
  - CCON-0001
  - CINST-000002
  - CROUTE-0001
  reason_category: supersession
  recorded_at: '2026-08-28T20:11:43-05:00'
  request_digest: sha256:a7abf7966d4c82510c0f4cc26dfffd67e0d89eb560fda9e1c0ef3a13bbcd52b6
  request_id: g11s-create-route-capdef-0001-ccon-0001-cinst-000002-supersedes-croute-0001
  trust_evidence_references: []
kind: capability-route
locality: local-only
provenance:
  class: declared
  recorded_at: '2026-08-28'
  source: docs/decisions/ADR-0012-distributed-capability-fabric.md
route_id: CROUTE-0002
route_version: 2
schema_version: schott-platform/v1
supersedes: CROUTE-0001
```

Field-by-field verification against the frozen body — **all agree**:

| Field | Value | |
|---|---|---|
| `route_id` | `CROUTE-0002` | OK |
| `capability_id` | `CAPDEF-0001` | OK |
| `contract_id` | `CCON-0001` | OK |
| `accepted_contract_versions` | `['1.0.0']` | OK |
| `locality` | `local-only` | OK |
| `candidate_instances` | `['CINST-000002']` | OK |
| `data_classification` | `internal` | OK |
| `route_version` | `2` | OK |
| `supersedes` | `CROUTE-0001` | OK |
| `evidence.actor` | `primary-platform-operator` | OK |
| `evidence.approving_authority` | `primary-platform-operator` | OK |
| `evidence.reason_category` | `supersession` | OK |
| `evidence.request_id` | matches the reviewed request | OK |
| `evidence.request_digest` | matches the reviewed digest | OK |
| `evidence.causal_references` | includes `CROUTE-0001` | OK |
| `evidence.trust_evidence_references` | `[]` — no invented Trust evidence | OK |

Absent optionals, confirmed genuinely absent rather than null: `overlap_window`,
`description`, `notes`, `superseded_by`. The released model serialises an absent
optional as absent, so `overlap_window` does not appear at all — the record carries
no overlap assertion, matching the `OVERLAP_POLICY = NONE` ruling.

## 8. Record SHA-256

```
path   /var/lib/kyri/fabric/capability-routes/CROUTE-0002.yaml
owner  cschott:cschott   mode 0600   size 884
sha256 1a7ed01877751ef70c8c25012cd947b23be9aa9a9c8cc17dacb6e79eba343870
```

## 9. Chain-head transition proof

**[1] Released helper**:

```
_chain_heads(store, 'capability-route') = ['CROUTE-0002']
```

**[2] Raw traversal / set difference**:

```
raw ids                      = ['CROUTE-0001', 'CROUTE-0002']
raw superseded set           = ['CROUTE-0001']
raw heads = ids - superseded = ['CROUTE-0002']
```

**[3] Direct record inspection**:

```
CROUTE-0002.supersedes          = 'CROUTE-0001'
CROUTE-0001.superseded_by       = None       (no backlink written)
CROUTE-0001.candidate_instances = ['CINST-000001']   (unchanged)
```

| Required | Observed |
|---|---|
| CROUTE count = 2 | true |
| route IDs = `CROUTE-0001`, `CROUTE-0002` | true |
| `CROUTE-0002` supersedes `CROUTE-0001` | true |
| `CROUTE-0001` acquires no `superseded_by` | true |
| unique current head = `CROUTE-0002` | true |
| `CROUTE-0001` no longer a head | true |

`_resolve_route` for the governed request class
(`CAPDEF-0001` / `CCON-0001` / `["1.0.0"]` / `internal` / `local-only`):

```
resolved route            : CROUTE-0002  version=2
exactly CROUTE-0002       : True   (no route-ambiguous-for-request-class)
candidate_instances       : ['CINST-000002']
CINST-000001 NOT a candidate of CROUTE-0002 : True
```

## 10. Route sequence

```
/var/lib/kyri/fabric/sequences/capability-route.seq = 2
```

## 11. Complete inventory

| Kind | Required | Observed |
|---|---|---|
| CAPDEF | 1 | 1 |
| CCON | 1 | 1 |
| CPKG | 1 | 1 |
| CHOST | 1 | 1 |
| CADV | 3 | 3 |
| CINST | 2 | 2 |
| CROUTE | 2 | **2** |
| CSEL | 0 | **0** |

## 12. Exact mutation accounting

Structural manifest, before → after — **one addition, zero removals, zero
modifications**:

```
> f 600 1000:1000 884 ./capability-routes/CROUTE-0002.yaml
```

Content manifest, before → after — **one addition and one in-place replacement**:

```
> 1a7ed018…3870  capability-routes/CROUTE-0002.yaml
< 4355a46b…d865  sequences/capability-route.seq          (was "1\n")
> 53c234e5…d3c3  sequences/capability-route.seq          (now "2\n")
```

As anticipated, the equal-length sequence replacement does **not** appear in the
structural diff. It is visible only because both manifests were taken. This is the
third consecutive production write where that has been true.

| Requirement | Observed |
|---|---|
| exactly one new governed route | yes — `CROUTE-0002.yaml` |
| exactly one route-sequence content replacement | yes |
| zero removals | yes |
| zero changed pre-existing governed records | yes |

Whole-authority digests before and after are identical:

| Authority | Digest | Change |
|---|---|---|
| Trust | `cffd362c…bc39` | none |
| Artifact | `30732e2c…257f` | none |
| Platform Evidence | `227abde8…984b` | none |
| Installed runtime (57 `.py`) | `80f9dee2…07b5f` | none |

The frozen operator input is also unchanged: `root:cschott 0640`, 676 bytes,
`dcbdae8c…02c5e`.

## 13. CROUTE-0001 byte-identity proof

```
before  6bf6aa0f06ff13e9787f7313d17f12f11d61de07b3cf4b9b8e26a7f191c48707
after   6bf6aa0f06ff13e9787f7313d17f12f11d61de07b3cf4b9b8e26a7f191c48707
```

Byte-identical. The predecessor was left exactly as written; supersession is stated
forward by the successor and read backwards, and nothing writes a backlink.

## 14. CINST records unchanged

```
CINST-000001  before/after  92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729
CINST-000002  before/after  5cfcf01e778856889c6aaa0838f986a0c43878033b29da1fd198be3070e3f719
CADV-000003   before/after  f2b48c2efbe6c1f547f538c6686b1dd0aa24fcbee664ac7ea08c6f5aa2e7116d
```

All byte-identical. A route write touches no binding.

## 15. Read-only production selection semantic proof

**No CSEL record was created.** Production still holds zero selections and no
`capability-selection.seq`. Two read-only mechanisms were exercised against the live
store; what each one does and does not prove is stated explicitly.

**(a) `eligibility.evaluate_eligibility`** — documented as writing nothing,
allocating nothing, and never raising. Evaluated at
`2026-08-28T20:20:50.603145-05:00` for the governed request class
(`CAPDEF-0001` / `CCON-0001` / `["1.0.0"]` / `internal`):

```
CINST-000002: eligible=True  unmet=none
  ELIG-1..ELIG-12 all met
CINST-000001: eligible=True  unmet=none
  ELIG-1..ELIG-12 all met
```

All twelve conditions hold for `CINST-000002`, which covers the required proofs:
the advertisement `CADV-000003` is fresh (ELIG-6), the admission window is open
(ELIG-7), Trust standings are valid, the host resolves, and the effective scope
permits `execute` / `internal` / `HOST-0001`.

`CINST-000001` is also still eligible *in itself* at this instant — expected, since
the cliff has not arrived. It is simply no longer reachable, because the current
route does not name it.

**Projection to the cliff instant**, read-only, same function:

```
at 2026-08-29T09:24:51-05:00
  CINST-000002: eligible=True   unmet=none
  CINST-000001: eligible=False  unmet=['ELIG-6']
```

This independently confirms the corrected deadline: `CINST-000001` fails ELIG-6
(`advertisement-not-fresh`) at exactly `09:24:51`, while `CINST-000002` is
unaffected.

**(b) Released `selection.select_candidate` under `admission.rehearsing()`** — the
non-allocating path the source provides. It requires no frozen decision body when
invoked as a released function, so no `/etc/kyri/fabric` selection input was
fabricated:

```
outcome            : preflight
record_id          : None          (nothing allocated)
selected instance  : 'CINST-000002'
refusal_reason     : None
CSEL count in production: 0
```

**Exactly what this call does and does not report.** Under rehearsal, `route_id`,
`route_version`, `considered_candidates`, and `excluded_candidates` come back as
`None`/empty. That is by design — `selection.py:521` notes that a rehearsal has no
record identity to read back from, so the path returns the decision without
constructing the full record. It is **not** evidence that no route was resolved.
Route resolution was proved separately and directly in section 9 via
`_resolve_route`, which returned `CROUTE-0002` with `candidate_instances =
['CINST-000002']`. I am stating this rather than presenting the rehearsal's empty
fields as if they were findings.

**Combined result**: the request class resolves to `CROUTE-0002`, whose sole
candidate is `CINST-000002`, which is eligible on all twelve conditions, and the
released selection path chooses `CINST-000002`. `CINST-000001` is not a candidate of
`CROUTE-0002`.

## 16. Selected instance

```
SELECTION_ROUTE     = CROUTE-0002
SELECTION_INSTANCE  = CINST-000002
SELECTION_ELIGIBLE  = YES
```

## 17. Routability gap

**`ROUTABILITY_GAP = NONE`.**

```
cutover accepted at  2026-08-28T20:19:35-05:00
routability cliff    2026-08-29T09:24:51-05:00
margin               13:05:16 before the cliff
```

The write landed **before** the deadline, and read-only selection proves
`CINST-000002` eligible and selected immediately after cutover. At no instant was
the governed request class without an eligible candidate: `CINST-000001` remained
eligible right up to the write, and `CINST-000002` was already eligible when the
route moved. The transition was continuous.

## 18. Validation after the write

| Check | Observed |
|---|---|
| Fabric inspection | `reported`, **zero defects** |
| Trust store | `valid: True`, **zero problems** |
| Generation 11 runtime | 57 `.py` files, digest unchanged |
| Root Authority | unmounted |

## 19. Route-head hardening deadline after this write

`ROUTE_HEAD_HARDENING_REQUIRED_BEFORE_NEXT_ROUTE_SUPERSESSION = YES`.

Production now contains **two** routes. Until this write, `CROUTE-0001` was the only
record of its kind and was therefore necessarily the head, which made the G11-K
non-head-predecessor defect unreachable. That protection is now gone: a future
`create_route` naming `supersedes: CROUTE-0001` instead of `CROUTE-0002` would be
**accepted** — `create_route` validates that the predecessor resolves, shares the
capability and contract, and has a lower `route_version`, but performs no head
check. The result would be a forked chain that `_chain_heads` reports as two heads
and `_resolve_route` then refuses as `route-ambiguous-for-request-class`, leaving
the request class unroutable until an operator resolves it.

The defect is now genuinely reachable. Hardening is required before `CROUTE-0003`,
any other route successor, or ENG-0005 closure — whichever occurs first. Not patched
here, as instructed.

## 20. CSEL-000001 readiness

`CSEL_000001_PREPARATION_READY = YES`. All four conditions hold:

- `CROUTE-0002` is the unique current route head;
- read-only selection resolves `CINST-000002`;
- Fabric valid, zero defects;
- Trust valid, zero problems.

The next checkpoint should derive and freeze the first production selection decision
body. `CSEL-000001` was **not** created here.

Two things worth deciding before that checkpoint. First, `capability-selection.seq`
does not yet exist; the first selection write will create it, so the mutation
footprint will be an added record **plus an added sequence file**, not a sequence
replacement — the manifest expectations differ from the last three writes. Second,
selection writes a record on refusal as well as on success, so a selection ceremony
has no read-only "would it succeed" outcome that leaves the store untouched other
than the rehearsal path exercised in section 15.

## 21. Actions not performed

- No `CSEL-000001`; no selection record in production at all.
- No `CROUTE-0003`; no second route write of any kind.
- `CROUTE-0001` not altered — proved byte-identical.
- `CINST-000001` not withdrawn, retired, edited, or given a lifecycle successor.
- No `CINST-000003`, no `CADV-000004`.
- No patch to route-head enforcement, withdrawn-binding routing, or replay semantics.
- No mutation of Trust, Artifact authority, or Platform Evidence.
- No runtime reinstall; no sudoers modification; no Root Authority mount.
- No package staged, no capability invoked.
- No ENG-0006 work; no TrustGateway cutover.
- No source or test change; no implementation commit.
- No fabricated `/etc/kyri/fabric` selection input.

## Appendix A — commands executed

```bash
# Mandatory pre-write checks
git rev-parse HEAD; git status --porcelain
git branch -r --contains 100df12ef56203f9dfe82c770019b8e0e5c8d3e5
stat -c '%U:%G %a %s' /etc/kyri/fabric/croute-0002.json
sha256sum /etc/kyri/fabric/croute-0002.json
cmp /etc/kyri/fabric/croute-0002.json <retained G11-S candidate>

# Both manifests, before
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )

# Final route-head proof (released helper + raw set difference)
#   selection._chain_heads / ids - superseded / direct record read

# Final approved-boundary preflight
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0002.json --approved-directory /etc/kyri/fabric

# THE AUTHORISED WRITE  (run once)
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0002.json --approved-directory /etc/kyri/fabric

# Post-write verification
# both manifests again, diffed; authority digests; record read-back;
#   selection._chain_heads, selection._resolve_route
#   eligibility.evaluate_eligibility  (now, and projected to the cliff)
#   selection.select_candidate under admission.rehearsing()
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001  kyri-execution-boundary-verification
CCON-0001    1.0.0, computational, deterministic
CPKG-0001    1.0.0
CHOST-0001   node identity HOST-0001
CADV-000001 → CADV-000002 → CADV-000003   head CADV-000003, valid_until 2026-08-30T16:19:19-05:00
CINST-000001 admitted, adv CADV-000002, ineligible from 2026-08-29T09:24:51-05:00 (ELIG-6),
             admitted_until 2026-08-29T13:46:27-05:00, binding root CINST-000001, no longer routed
CINST-000002 admitted, adv CADV-000003, admitted_until 2026-08-30T16:19:19-05:00,
             binding root CINST-000002, supersedes CINST-000001, ELIG-1..12 all met
CROUTE-0001 → CROUTE-0002                 head CROUTE-0002, route_version 2,
             candidate_instances ['CINST-000002'], no overlap window
CSEL         none
```
