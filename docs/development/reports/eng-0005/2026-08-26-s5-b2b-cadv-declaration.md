# ENG-0005 S5-B2B — Final Preflight and Declaration of CADV-000001

**Date:** 2026-08-26
**Checkpoint:** S5-B2B
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Re-establish all production authority, verify the frozen
`CADV-000001` operator input exactly, run the real production preflight from
`/etc/kyri/fabric`, and — only if every invariant matched — perform exactly one
`register-advertisement` write. Then verify the durable record, prove every
other authority plane unchanged, and stop before CINST.

**Outcome: ACCEPTED.**

`CADV-000001` exists. It is the first governed capability advertisement in this
fabric: `CHOST-0001` claiming, of itself, that it holds `CPKG-0001` and
satisfies contract version `1.0.0` of `CCON-0001`.

- Every Phase 0 gate passed, including the frozen input's digest, metadata, link
  count and expiry margin.
- Phase 1 preflight matched **every** expected invariant, and its request digest
  was **identical** to the one S5-B2A recorded — `sha256:f8b1a426…a38a` — proving
  the published bytes are the reviewed bytes.
- Exactly **one** write was performed. It was not re-run.
- Phase 3 verified 24 assertions against the durable record.
- Phase 6 proved the advertisement fresh through the committed ELIG-6 helper at
  explicit instants, with no ambient time and **no CINST created**.
- Trust, the artifact authority and Platform Evidence are **byte-identical**.
  `CINST`, `CROUTE` and `CSEL` remain 0 with their sequence files absent.

**Stopped before CINST**, as ruled. The next checkpoint is the Generation-11
execution-readiness correction, not instance admission (§14).

| | |
|---|---|
| **CADV_ID** | `CADV-000001` |
| **Durable record** | `/var/lib/kyri/fabric/capability-advertisements/CADV-000001.yaml` |
| **Record SHA-256** | `cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195` |
| **Request digest** | `sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a` |
| **Valid until** | `2026-08-27T14:13:53-05:00` |

---

## 2. Starting authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | identical | PASS |
| HEAD contains | `5860f2abca900625e02106d3ff54a8b9840113b6` | HEAD **is** `5860f2ab…` | PASS |
| Worktree | clean | clean, no untracked | PASS |
| Fabric contents | exactly CAPDEF/CCON/CPKG/CHOST-0001 | exactly those four | PASS |
| CADV count | 0 | 0 | PASS |
| `capability-advertisement.seq` | absent | absent | PASS |
| Next identity | `CADV-000001` | `CADV-000001` (read-only peek) | PASS |
| Trust | validates clean | `valid: true`, `problems: []` | PASS |
| `TREC-000001` | verifies | `verified`, `HOST-0001`, `fabric-node` | PASS |
| `TREC-000002` | verifies | `verified`, `CPKG-0001`, `capability-package` | PASS |
| Artifact authority | unchanged | `63db66fd…8bec25` | PASS |
| Platform Evidence | unchanged | `227abde8…20984b` | PASS |
| Root Authority | unmounted | not a mountpoint | PASS |

```
Fabric   9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
          counts: authority 1, record 2, decision 2, evidence 7, lineage 3, audit 4
Artifact 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b

Fabric sequences before: capability-contract, capability-definition,
                         capability-host, capability-package, request_identity.lock
CADV = 0   CINST = 0   CROUTE = 0   CSEL = 0
```

---

## 3. Frozen operator input — digest and metadata

```
$ stat -c 'type=%F owner=%U:%G mode=%a size=%s links=%h' /etc/kyri/fabric/cadv-000001.json
  type=regular file  owner=root:cschott  mode=640  size=609  links=1

$ sha256sum /etc/kyri/fabric/cadv-000001.json
  2cc13b39219f11d29f9968f959e4050257093d70aa7a2a285eda9b8270c6bd01
```

| Property | Authorized | Observed | |
|---|---|---|---|
| SHA-256 | `2cc13b39219f11d29f9968f959e4050257093d70aa7a2a285eda9b8270c6bd01` | identical | PASS |
| Size | 609 bytes | 609 | PASS |
| Owner:group | `root:cschott` | `root:cschott` | PASS |
| Mode | `0640` | `640` | PASS |
| Type | regular file | regular file | PASS |
| Link count | 1 | 1 | PASS |
| JSON | valid | valid | PASS |

The published file was additionally `cmp`-verified **byte-identical** to the
S5-B2A reviewed scratch body — the operator published exactly what was reviewed,
not merely something with a matching digest.

### Expiry margin at the time of the write

```
now         : 2026-08-26T15:41:45-05:00
valid_until : 2026-08-27T14:13:53-05:00
remaining   : 22.54 hours
verdict     : BEFORE expiry — may proceed
```

The R13 invariant is judged against the body's own `recorded_at`, so the
relevant question was whether the write would land before `valid_until`. It did,
with 22.54 hours to spare.

---

## 4. Phase 1 — final production preflight

Run from the **production** approved directory, not the S5-B2A scratch one.

```
$ python3 -m tools.fabric.cli register-advertisement --preflight \
    --store-root /var/lib/kyri/fabric \
    --expected-uid 1000 --expected-gid 1000 \
    --input-file cadv-000001.json \
    --approved-directory /etc/kyri/fabric
```

Exit 0. Complete output:

```json
{
  "destination": "/var/lib/kyri/fabric/capability-advertisements/CADV-000001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "register-advertisement",
  "outcome": "preflight",
  "predicted_record_id": "CADV-000001",
  "record_kind": "capability-advertisement",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a",
  "request_id": "s5b2-register-advertisement-cpkg-0001-chost-0001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

### Required invariants — all matched

```
PASS  outcome == 'preflight'
PASS  would_accept == True
PASS  mutated == False
PASS  predicted_record_id == 'CADV-000001'
PASS  destination_exists == False
PASS  record_kind == 'capability-advertisement'
PASS  rehearsal_outcome == 'preflight'
PASS  rehearsal_reason == None
```

### Request digest, re-derived in full

```
S5-B2A recorded : sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a
S5-B2B observed : sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a
PASS  request digest matches S5-B2A exactly
PASS  request_id matches: s5b2-register-advertisement-cpkg-0001-chost-0001
```

The complete digest is reported above rather than the abbreviated prompt value.
Its equality across checkpoints is the load-bearing check: the digest is computed
from the request body, so an identical digest read from a *different* directory
proves the published bytes are the reviewed bytes.

### Body-derived semantics — all confirmed

```
PASS  actor == CHOST-0001
PASS  capability_host_id == CHOST-0001
PASS  capability_package_id == CPKG-0001
PASS  contract_id == CCON-0001
PASS  satisfied_contract_versions == ["1.0.0"]
PASS  advertised_resource_profile == {"architecture": "x86-64"}
PASS  observed_at == recorded_at                  2026-08-26T14:13:53-05:00
PASS  valid_until - observed_at == 24 hours       delta=1 day, 0:00:00
PASS  observed_at <= recorded_at < valid_until
PASS  approving_authority absent
PASS  supersedes / superseded_by / notes absent
```

### Preflight mutated nothing

```
Fabric    9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a  unchanged
CADV count                     : 0
capability-advertisement.seq   : does not exist
Trust     cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39  unchanged
Artifact  63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25  unchanged
Evidence  227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b  unchanged
```

---

## 5. Phase 2 — the one authorized production write

```
$ python3 -m tools.fabric.cli register-advertisement \
    --store-root /var/lib/kyri/fabric \
    --expected-uid 1000 --expected-gid 1000 \
    --input-file cadv-000001.json \
    --approved-directory /etc/kyri/fabric
```

Exit 0. Complete mutation output:

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CADV-000001",
  "record_kind": "capability-advertisement",
  "request_digest": "sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a",
  "request_id": "s5b2-register-advertisement-cpkg-0001-chost-0001"
}
```

| Required | Observed |
|---|---|
| `outcome: accepted` | `accepted` |
| `record_id: CADV-000001` | `CADV-000001` |
| `record_kind: capability-advertisement` | `capability-advertisement` |

Executed **exactly once**, and **not re-run after success**. The request digest
is identical to the preflight's, so the write carried the same request the
rehearsal evaluated.

---

## 6. Phase 3 — the durable record

```
path   : /var/lib/kyri/fabric/capability-advertisements/CADV-000001.yaml
meta   : cschott:cschott  0600  875 bytes  links=1  regular file
sha256 : cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195
```

Complete stored content:

```yaml
advertised_resource_profile:
  architecture: x86-64
advertisement_id: CADV-000001
capability_host_id: CHOST-0001
capability_package_id: CPKG-0001
contract_id: CCON-0001
evidence:
  actor: CHOST-0001
  approving_authority: null
  causal_references:
  - CHOST-0001
  - CPKG-0001
  - CCON-0001
  reason_category: advertisement-registration
  recorded_at: '2026-08-26T14:13:53-05:00'
  request_digest: sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a
  request_id: s5b2-register-advertisement-cpkg-0001-chost-0001
  trust_evidence_references: []
kind: capability-advertisement
observed_at: '2026-08-26T14:13:53-05:00'
provenance:
  class: declared
  recorded_at: '2026-08-26'
  source: docs/decisions/ADR-0012-distributed-capability-fabric.md
satisfied_contract_versions:
- 1.0.0
schema_version: schott-platform/v1
valid_until: '2026-08-27T14:13:53-05:00'
```

### Required assertions

```
PASS  advertisement_id == CADV-000001
PASS  capability_host_id == CHOST-0001
PASS  capability_package_id == CPKG-0001
PASS  contract_id == CCON-0001
PASS  satisfied_contract_versions == ["1.0.0"]
PASS  advertised_resource_profile.architecture == x86-64
PASS  observed_at == 2026-08-26T14:13:53-05:00
PASS  valid_until == 2026-08-27T14:13:53-05:00
PASS  kind == capability-advertisement
```

### `actor` and `approving_authority` — carried in the evidence block

Both are represented in the record's `evidence` block rather than as top-level
fields, as the released model files them. Verified there:

```
PASS  evidence.actor == CHOST-0001
PASS  evidence.approving_authority is absent (null)
PASS  evidence.reason_category == advertisement-registration
PASS  evidence.request_digest matches preflight and write
PASS  evidence.request_id matches
PASS  evidence.recorded_at == the frozen ceremony instant
PASS  evidence.causal_references == [CHOST-0001, CPKG-0001, CCON-0001]
PASS  evidence.trust_evidence_references empty (a claim cites no trust)
```

`approving_authority: null` is the durable proof that no human approval was
recorded: the operation refuses any non-null value, because *"recording one
would make a self-report into an approval."*

`trust_evidence_references: []` is the durable proof that **this record cites no
trust standing**. An advertisement is a claim; the trust gate is at
`admit_instance`, not here.

### The claim grants nothing

```
PASS  no forbidden field present  []
PASS  supersedes / superseded_by / notes not populated
PASS  provenance keys == {class, source, recorded_at}
PASS  provenance.class == declared
```

Checked against the schema's full `forbidden_fields` list — `trust_state`,
`trusted`, `trust_score`, `auto_admit`, `auto_enroll`, `auto_approve`,
`scope_grant`, `admitted`, `admission_decision_id`, `route_id`, `priority`,
`weight`, `peer_hosts`, `token`, `secret`, `credential`, `private_key`,
`password`, `command`. None is present.

**24 of 24 Phase 3 assertions pass.**

---

## 7. Phase 4 — sequence and inventory

```
capability-advertisement.seq = 1
CADV count   = 1
CINST count  = 0
CROUTE count = 0
CSEL count   = 0

capability-instance.seq  : does not exist
capability-route.seq     : does not exist
capability-selection.seq : does not exist

sequences now present: capability-advertisement, capability-contract,
                       capability-definition, capability-host,
                       capability-package, request_identity.lock
```

Complete Fabric inventory — exactly the five expected records:

```
capability-advertisements/CADV-000001.yaml
capability-contracts/CCON-0001.yaml
capability-definitions/CAPDEF-0001.yaml
capability-hosts/CHOST-0001.yaml
capability-packages/CPKG-0001.yaml
```

The advertisement sequence was created by this write and stands at exactly `1`.
The instance, route and selection sequences remain **absent** — nothing has
asked for one of those identities.

---

## 8. Fabric before / after

```
before : 9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a
after  : 7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
```

The Fabric digest changed, as it must: one record and one sequence file were
added. The four pre-existing governed records are individually unchanged (§9).

---

## 9. Phase 5 — cross-plane integrity

| Authority | Before | After | Result |
|---|---|---|---|
| Trust `/var/lib/kyri/trust` | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifact `/var/lib/kyri/artifacts` | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence `/var/lib/kyri/evidence` | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |

```
Trust validate-store : valid true, problems []
Trust counts         : authority 1, record 2, decision 2, evidence 7, lineage 3, audit 4
                       — unchanged in every kind
```

Individual governed records, digested after the write:

```
TREC-000001   0c5e71cfd847c752…   unchanged
TREC-000002   c89c5d53ec6c7b51…   unchanged
CHOST-0001    f7ca6fcabe0d446f6cc31f5603df273188a6927c550c44a86965ac706bb3c7aa   unchanged
CPKG-0001     ff78628e216b1f188fe5448e0d7354fe7c326d6506e9931a003ab337f9bd7b60   unchanged
CAPDEF-0001   f638df9036e2fe87…   unchanged
CCON-0001     8ada52704d537e81…   unchanged
```

```
Root Authority /mnt/kyri-root : unmounted, not a mountpoint
Staged trees under /var/lib/kyri : 0
```

The advertisement is purely additive: it created its own record and its own
sequence, and touched nothing else in any plane.

---

## 10. Phase 6 — freshness verification

Evaluated through the **committed** ELIG-6 helper
`tools.fabric.eligibility._advertised`, against the real stored record, at
**explicit instants only**. The helper takes an evaluation instant as a
parameter and no ambient time was used.

**No `CapabilityInstance` was created.** The helper reads an
`advertisement_id` from a mapping, so a plain `{"advertisement_id":
"CADV-000001"}` exercises the real condition without writing anything.

```
=== ELIG-6 freshness, committed helper, explicit instants only ===
PASS  observed_at + 1 hour  (required)       2026-08-26T15:13:53-05:00  -> FRESH

  window boundaries, for completeness:
PASS  observed_at            (inclusive start) 2026-08-26T14:13:53-05:00  -> FRESH
PASS  observed_at + 12 hours (interior)        2026-08-27T02:13:53-05:00  -> FRESH
PASS  valid_until - 1 second (last fresh)      2026-08-27T14:13:52-05:00  -> FRESH
PASS  valid_until            (exclusive end)   2026-08-27T14:13:53-05:00  -> NOT FRESH (advertisement-not-fresh)
PASS  valid_until + 1 hour   (lapsed)          2026-08-27T15:13:53-05:00  -> NOT FRESH (advertisement-not-fresh)
PASS  observed_at - 1 hour   (before start)    2026-08-26T13:13:53-05:00  -> NOT FRESH (advertisement-not-fresh)
```

**At the required instant `observed_at + 1 hour`, `CADV-000001` is FRESH.**

The boundary probes confirm the window is half-open `[observed_at, valid_until)`
— inclusive at the start, exclusive at the end — matching
`observed <= instant < expires` in `eligibility.py:553`, and confirm the lapse
reason is `advertisement-not-fresh`, distinct from the registration-time
`invalid-validity-window`.

After the probe: `CINST = 0, CROUTE = 0, CSEL = 0`, Fabric digest
`7780dacf…ab072` — unchanged from immediately after the write.

---

## 11. Final production state

```
Fabric /var/lib/kyri/fabric   7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
  CAPDEF-0001   capability-definition
  CCON-0001     capability-contract      version 1.0.0
  CPKG-0001     capability-package       trusted as TREC-000002
  CHOST-0001    capability-host          trusted as TREC-000001
  CADV-000001   capability-advertisement valid until 2026-08-27T14:13:53-05:00
  CADV = 1   CINST = 0   CROUTE = 0   CSEL = 0
  capability-advertisement.seq = 1
  instance / route / selection sequences: absent

Trust /var/lib/kyri/trust     cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
  valid true, problems []
  TREC-000001  HOST-0001  fabric-node         trusted
  TREC-000002  CPKG-0001  capability-package  trusted
  effective authority: CAPDEF-0001 / execute / internal / HOST-0001

Artifact  63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25  unchanged
Evidence  227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b  unchanged
Root Authority                                                              unmounted
Repository                    5860f2abca900625e02106d3ff54a8b9840113b6, clean at ceremony
```

Every precondition `admit_instance` requires now exists: two verified trust
standings and a fresh advertisement. **That admission is deliberately not
performed** — see §14.

---

## 12. Execution-readiness ledger

| # | Finding | Status |
|---|---|---|
| 1 | `CapabilityInstance.advertisement_id` must become non-optional — modeled optional while `admit_instance` requires it | **ACTIVE** — before CINST |
| 2 | `admit_instance` must require the admitted host to belong to `effective_scope["permitted_targets"]`. Targets is only intersected for non-emptiness (`admission.py:597-617`), never compared to the node, unlike capabilities (`:1534`) and classifications (`:1539`). Tests: `effective HOST-0001 + admitted HOST-0001 → accept`; `+ admitted HOST-0002 → refuse` | **ACTIVE** — before CINST |
| 3 | Installed Capability runtime lacks `tools.fabric` dependency closure — `/usr/lib/kyri/python/tools/` holds only `capability` and `common`, while installed `fabric_evidence.py` and `coordinator.py` import `tools.fabric` | **ACTIVE** |
| 4 | Generation 11 should package the existing `tools.fabric` rather than duplicate Fabric logic, unless dependency-closure inspection disproves it | **ACTIVE** |
| 5 | `select` lacks genuine read-only preflight; required before `CSEL-000001` is spent | **ACTIVE** |
| 6 | Advertisement admission-time stale/future-window defect | **CLOSED** in S5-B1, commit `90597fe9e934447dd2bb08c551f160b605c20973`. R13 invariant `observed_at <= recorded_at < valid_until` enforced; validator 91/91. Exercised in production for the first time by this checkpoint — the frozen body satisfied it and was accepted |
| 7 | Advertisement renewal/supersession must be established before `CADV-000002` — `supersedes`, `superseded_by` and `notes` are declared but unreachable by any released operation, so a renewal today would be an unlinked new record | **ACTIVE** — now the nearest-term blocker, because `CADV-000001` expires `2026-08-27T14:13:53-05:00` |

Carried observation, not a blocker: all three invalid temporal relationships
report the single reason `invalid-validity-window`, so a caller reading only the
token cannot distinguish a reversed window from an already-closed one from a
future observation. Deliberate, per R13's preference for reuse.

**No blocker was implemented in this checkpoint.**

---

## 13. Actions explicitly NOT performed

- **No CINST created.** Count 0; `capability-instance.seq` absent. `admit_instance`
  was never called.
- **No CROUTE, no CSEL.** Both 0; their sequences absent.
- **No second advertisement write.** The operation ran exactly once and was not
  re-run after success.
- **No package staged.** `resolve_and_stage_package` was never called; zero
  staged trees exist anywhere under `/var/lib/kyri`.
- **Nothing invoked.**
- **Trust not altered** — byte-identical, still 2 records, `valid: true`.
- **Artifact authority not altered. Platform Evidence not altered.**
- **Root Authority not mounted.**
- **Generation 11 not opened. Nothing installed.**
- **No implementation source changed.** The report commit contains one file.
- **No frozen operator input modified** — `/etc/kyri/fabric/cadv-000001.json`
  was read only, and no `sudo` was used at any point.
- **No ambient time used** in the freshness verification; every instant was
  supplied explicitly.
- **No secrets recorded.**

---

## 14. Recommended next checkpoint

**Generation-11 execution-readiness correction — before CINST.**

Both trust standings and a fresh advertisement now exist, so `admit_instance` is
reachable for the first time. It is deliberately not attempted, because two
active blockers bear directly on it and one of them would let a wrong record
become permanent:

- **Blocker 1** — `advertisement_id` is modeled optional while `admit_instance`
  requires it. The model is not authoritative about what a valid instance is.
- **Blocker 2** — `admit_instance` never checks that the admitting host is in
  `effective_scope["permitted_targets"]`. With one host this is invisible; with a
  second it is a real gap, and a `CapabilityInstance` is immutable.

Suggested scope for the next checkpoint: close blockers 1 and 2 with RED-first
tests, and inspect the dependency closure that blockers 3 and 4 describe.

**A timing note the reviewer should weigh.** `CADV-000001` lapses at
`2026-08-27T14:13:53-05:00`. Nothing breaks when it does — it stays a durable
historical record and simply stops satisfying ELIG-6, which is exactly what
`on_stale: instance-ineligible` specifies. But **any future CINST will need a
fresh advertisement**, and blocker 7 says there is no governed renewal path yet.
So the practical ordering is: fix blockers 1 and 2, establish the renewal
mechanism (blocker 7), then register a fresh advertisement and admit an instance
against it. Racing a CINST before the current window closes would invert the
ruling that blockers come first.

---

## Appendix A — commands executed

```bash
# Phase 0
git rev-parse HEAD ; git rev-parse --abbrev-ref HEAD ; git status --porcelain
stat -c '%F %U:%G %a %s %h' /etc/kyri/fabric/cadv-000001.json
sha256sum /etc/kyri/fabric/cadv-000001.json
cmp /etc/kyri/fabric/cadv-000001.json /tmp/s5-b2a-scratch/approved/cadv-000001.json
python3 -c "<expiry margin against 2026-08-27T14:13:53-05:00>"
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
python3 -c "<verify_trust_record TREC-000001, TREC-000002>"
python3 -c "<FabricStore.open_for_read(...).peek_next_id('capability-advertisement')>"
<whole-tree digests: fabric, trust, artifacts, evidence>

# Phase 1 — final preflight from the production approved directory
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000001.json --approved-directory /etc/kyri/fabric
python3 -c "<assert 8 preflight invariants, digest equality, 11 body semantics>"
<non-mutation digests>

# Phase 2 — THE ONE AUTHORIZED WRITE   *** MUTATES ***
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000001.json --approved-directory /etc/kyri/fabric

# Phases 3-5
stat / sha256sum / cat  capability-advertisements/CADV-000001.yaml
python3 -c "<24 durable-record assertions incl. forbidden-field sweep>"
<sequence and inventory listing; per-record digests; trust validate-store>

# Phase 6 — freshness, explicit instants, no CINST
python3 -c "<tools.fabric.eligibility._advertised at 7 instants>"
```

## Appendix B — what CADV-000001 records, and what it does not

From the governing schema, restated so the record's standing is unambiguous:

```
record_class              : claim
confers_trust             : false
confers_eligibility       : false
creates_instance          : false
may_modify_trust_state    : false
requires_admitted_subject : true
mutability                : immutable  (update_methods: none, delete_methods: none)
on_absent                 : capability-absent
on_stale                  : instance-ineligible
renews_admission          : false
renews_trust              : false
```

`CADV-000001` records that `CHOST-0001` claims, of itself, that it holds
`CPKG-0001`, satisfies contract version `1.0.0` of `CCON-0001`, and has
architecture `x86-64` — and that this was true at `2026-08-26T14:13:53-05:00`
and is offered as current until `2026-08-27T14:13:53-05:00`.

It grants nothing. It confers no trust and no eligibility, admits no instance,
cannot admit itself, and cannot move either trust standing — `evidence.
trust_evidence_references` is empty and `evidence.approving_authority` is null,
both durably. When its window closes it becomes stale, not absent: the record
remains readable for ever, because what a host claimed about itself and when is
exactly what the audit requirement in ADR-0012 asks to be retained.
