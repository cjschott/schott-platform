# ENG-0005 S5-A1 — Authorize CPKG-0001 Capability-Package Trust Standing

**Date:** 2026-08-26
**Checkpoint:** S5-A1
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Checkpoint objective and outcome

**Objective.** Perform exactly ONE production Trust mutation establishing the
governed Trust standing of the capability package `CPKG-0001`, producing Trust
record `TREC-000002`, using only the operator input frozen and rehearsed in
S5-A0. No other production mutation authorized.

**Outcome: ACCEPTED.** `TREC-000002` exists, is `trusted`, and its durable
record and decision fingerprints match the S5-A0 rehearsal predictions byte for
byte. The Trust store validates clean. Fabric, the artifact authority and the
Platform Evidence authority are byte-identical. No advertisement, instance,
route or selection was created. Nothing was staged, nothing was invoked, and
the Root Authority was never mounted.

Both trust standings that `admit_instance` requires now exist:

| Record | Subject | Domain | State |
|---|---|---|---|
| `TREC-000001` | `HOST-0001` | `fabric-node` | `trusted` |
| `TREC-000002` | `CPKG-0001` | `capability-package` | `trusted` |

Composed effective authority: **`CAPDEF-0001` / `execute` / `internal` / `HOST-0001`**.

---

## 2. Starting branch and HEAD

```
repository : /opt/schott-platform
branch     : arch/eng-0005-execution-transition
HEAD       : 656335f48872e13ca0ce10d482b14ca58992261b
worktree   : clean, no untracked files
```

HEAD was verified unchanged immediately before the mutation and immediately
after. **No implementation source was changed in this checkpoint.** The only
repository change is this report (see §22).

## 3. Starting durable authority

| Authority | Root | State at start of S5-A1 |
|---|---|---|
| Trust store | `/var/lib/kyri/trust` | 1 ordinary record, `valid: true` |
| Fabric | `/var/lib/kyri/fabric` | CAPDEF/CCON/CPKG/CHOST ×1 each; 0 CADV/CINST/CROUTE/CSEL |
| Artifact authority | `/var/lib/kyri/artifacts` | one published tree + manifest, `root:root`, `0444`/`0555` |
| Platform Evidence | `/var/lib/kyri/evidence` | `EVID-000001.yaml`, `root:root`, `0444` |
| Operator inputs | `/etc/kyri/trust` | `cschott:cschott`, `0700` dirs, `0600` files |
| Root Authority | `/mnt/kyri-root` | **unmounted**, empty, no secret key material present |

Whole-tree digests at start:

```
Trust            cf6d651c999716849251f67dd969198d65445e5e63cb688684d218c21beedd5a
Fabric           9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a
Artifacts        63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
PlatformEvidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
/etc/kyri/trust  4822f2ef24bf137af3dd26fe260ebbc10ca67cbe77ea0768756cc35cf7b16cd7
```

Pre-existing Trust content: `TAUTH-000001` (operator root), `TREC-000001`,
`TDEC-000001`, `TEVID-000001..000006`, `TLIN-000001` (root establishment),
`TLIN-000002` (HOST-0001), `TAUDIT-000001..000003`.

---

## 4. Architecture and reviewer rulings applied

Rulings carried in from the accepted S5-A0 review and applied without deviation:

1. **Package Trust rests only on mechanically established package authority** —
   `CPKG-0001`, `CAPDEF-0001`, `CCON-0001`, the governed artifact reference, the
   published manifest, and the governed tree commitment.
2. **Trust evidence may state** that `CPKG-0001` is the governed Fabric package
   record; that it binds `CAPDEF-0001` and `CCON-0001`; that its manifest exists
   in the trusted artifact authority; that the manifest binds those identities
   to the published tree; that the published tree verifies against the governed
   commitment; and that the artifact was materialized from the previously
   reviewed source per the accepted publication ceremony.
3. **Trust evidence must NOT claim** absence of vulnerabilities, general code
   safety, production workload suitability, cryptographic publisher identity, or
   any property not established by the package/artifact ceremony. The frozen
   evidence names all of these explicitly under `not_established`.
4. **Intended scope** `CAPDEF-0001` / `execute` / `internal` / `HOST-0001`,
   with **no expiration**.
5. **Verification method** `reviewed-source-inspection`. The alternative
   committed token `checksum-against-signed-manifest` was considered and
   **rejected in S5-A0**: nothing signs this manifest, and using that token would
   assert a cryptographic publisher identity the ceremony did not establish.
6. **Target-scope semantic ruling (S5-A0, re-affirmed here).**
   `permitted_targets: [HOST-0001]` is semantically valid for a
   `capability-package` Trust subject **and is required**. The Trust plane treats
   `permitted_targets` as an opaque non-wildcard token set with no subject-type
   reinterpretation (`tools/trust/models.py:273-314`); `_effective_scope`
   (`tools/fabric/admission.py:597-617`) intersects the dimension across package
   standing, host standing and the operator admission bound. Host standing
   `TREC-000001` permits `HOST-0001`, so a package scope omitting it would make
   the intersection empty and admission would refuse with
   `empty-effective-scope`. Proven mechanically in S5-A0 and again in §14.
7. **Binding constraint discovered in S5-A0 and honoured:**
   `trust_scope.subject_type` must equal the record's `subject_type`, because
   `verify_trust_record` (`tools/fabric/trust_adapter.py:520-522`) refuses a
   grant declaring a different domain than the record carrying it.

---

## 5. Exact frozen-input and evidence digests

Neither file was regenerated, edited, normalized, reserialized or replaced at
any point in S5-A1. Both were used verbatim.

| File | Required SHA-256 | Observed | Result |
|---|---|---|---|
| `/etc/kyri/trust/inputs/trec-0002-capability-package-cpkg-0001.yaml` | `1a9e9c1f19c30721259760b95f013151998e88737d1d2661d7deae5286fdebff` | identical | **PASS** |
| `/etc/kyri/trust/evidence/capability-package/CPKG-0001-verification.yaml` | `bd9a5597b91733150512183eb2e6079ac1480b115a417af515e4696cc5a60ef4` | identical | **PASS** |

```
$ sha256sum /etc/kyri/trust/inputs/trec-0002-capability-package-cpkg-0001.yaml \
            /etc/kyri/trust/evidence/capability-package/CPKG-0001-verification.yaml
1a9e9c1f19c30721259760b95f013151998e88737d1d2661d7deae5286fdebff  .../trec-0002-capability-package-cpkg-0001.yaml
bd9a5597b91733150512183eb2e6079ac1480b115a417af515e4696cc5a60ef4  .../CPKG-0001-verification.yaml
```

Both files remain `cschott:cschott`, mode `0600`; the evidence directory
`/etc/kyri/trust/evidence/capability-package/` is `0700`. Ownership and modes
were derived in S5-A0 from the existing Trust operator inputs. No root privilege
was required at any point, and `sudo` was never used.

---

## 6. Phase 0 — pre-write authority gate

All gates passed before the mutation.

| Gate | Required | Observed | Result |
|---|---|---|---|
| HEAD | `656335f48872e13ca0ce10d482b14ca58992261b` | identical | PASS |
| Branch | `arch/eng-0005-execution-transition` | identical | PASS |
| Worktree | clean | clean, no untracked files | PASS |
| `validate-store` | `valid: true`, `problems: []` | identical | PASS |
| Ordinary Trust records | exactly 1 | `TREC-000001.yaml` only | PASS |
| `TREC-000001` | `HOST-0001` / `fabric-node` / `trusted` | identical | PASS |
| Trust whole-tree digest | `cf6d651c…eedd5a` | identical | PASS |
| Input digest | `1a9e9c1f…debff` | identical | PASS |
| Evidence digest | `bd9a5597…60ef4` | identical | PASS |
| Root Authority | unmounted | not a mountpoint, 0 entries, 0 secret keys | PASS |

### Decision-input body gate — 12/12 PASS

```
PASS  top-level subject_type == capability-package
PASS  trust_scope.subject_type == capability-package
PASS  subject_id == CPKG-0001
PASS  requested_state == trusted
PASS  actor_authority_id == TAUTH-000001
PASS  verification_method == reviewed-source-inspection
PASS  expiration is null
PASS  scope.permitted_capabilities         == ['CAPDEF-0001']
PASS  scope.permitted_operations           == ['execute']
PASS  scope.permitted_data_classifications == ['internal']
PASS  scope.permitted_targets              == ['HOST-0001']
PASS  evidence cites TEVID-000007
```

### Next-identity gate — peek only, spent nothing

`TrustStore.peek_next_id` reads the sequence and advances nothing.

```
PASS  record    next = TREC-000002      PASS  scope    next = TSCOPE-000002
PASS  decision  next = TDEC-000002      PASS  lineage  next = TLIN-000003
PASS  evidence  next = TEVID-000007     PASS  audit    next = TAUDIT-000004
```

---

## 7. Phase 1 — final production preflight

```
$ python3 -m tools.trust.cli create-decision --preflight \
    --store-root /var/lib/kyri/trust \
    --input-file trec-0002-capability-package-cpkg-0001.yaml \
    --approved-directory /etc/kyri/trust/inputs
```

Complete output (exit 0):

```json
{
  "decision_fingerprint": "sha256:525ae4f35dfc142004626e55be9b15ee888cb3fd02d1a13dc5c0dd5be237b8da",
  "destination": "/var/lib/kyri/trust/records/TREC-000002.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "create-decision",
  "outcome": "preflight",
  "predicted_audit_id": "TAUDIT-000004",
  "predicted_decision_id": "TDEC-000002",
  "predicted_evidence_ids": ["TEVID-000007"],
  "predicted_lineage_id": "TLIN-000003",
  "predicted_record_id": "TREC-000002",
  "predicted_scope_id": "TSCOPE-000002",
  "record_fingerprint": "sha256:703d15ff2f74f071efde0448f4e4f51af9ddd8c6059aba0a1b81726b1e27b8f0",
  "state": "trusted",
  "store_root": "/var/lib/kyri/trust",
  "subject_fingerprint": "sha256:46594a1674a8201519895e3b6b765edd19f5f21a44fd272610a35c11282f8449",
  "subject_id": "CPKG-0001",
  "subject_type": "capability-package",
  "would_accept": true
}
```

All 13 required assertions PASS, including both mandated fingerprints. The Trust
whole-tree digest immediately after the preflight was still
`cf6d651c…eedd5a` — the rehearsal mutated nothing.

**How preflight achieves non-mutation** (recorded for the reviewer, since it is
a trust-relevant property rather than an obvious one): `--preflight` opens the
store through `TrustStore.open_for_read` (`initialize=False`) and runs
`create_decision` inside the `rehearsing()` context variable. `_Identities.take`
then resolves to `peek_next_id` instead of `allocate_id`, and the evaluator
returns before the first `store.write`. It is **not** a store that mechanically
refuses writes; the guarantee is the rehearsal short-circuit plus the observed
byte-identity of the tree. Both were checked.

---

## 8. Phase 2 — the ONE authorized production mutation

```
$ python3 -m tools.trust.cli create-decision \
    --store-root /var/lib/kyri/trust \
    --input-file trec-0002-capability-package-cpkg-0001.yaml \
    --approved-directory /etc/kyri/trust/inputs
```

Exit 0. Executed exactly once. The two `reason` bodies in the output are the
same 1897-character text, reproduced once in §12 rather than three times.

```json
{
  "audit_event": {
    "actor_authority_id": "TAUTH-000001",
    "audit_id": "TAUDIT-000004",
    "event_kind": "trust-decision-created",
    "fingerprint": "sha256:534b916ffbc99fb39a946d81b1ecbbbc5cb7d426a83b4749a174bc986a3d62eb",
    "id": "TAUDIT-000004",
    "lineage_id": "TLIN-000003",
    "occurred_at": "2026-08-26T12:28:05-05:00",
    "provenance": {},
    "reason": "<see §12 — the decision reason, verbatim>",
    "related_record_ids": ["TDEC-000002", "TREC-000002", "TLIN-000003-v0001",
                           "lineage-created", "trust-decision-created"],
    "subject_id": "CPKG-0001"
  },
  "decision": {
    "actor": "TAUTH-000001",
    "actor_authority_id": "TAUTH-000001",
    "approval_source": "named-operator",
    "decided_at": "2026-08-26T12:28:05-05:00",
    "decision_fingerprint": "sha256:525ae4f35dfc142004626e55be9b15ee888cb3fd02d1a13dc5c0dd5be237b8da",
    "decision_id": "TDEC-000002",
    "evidence": [
      { "evidence_id": "TEVID-000007", "id": "TEVID-000007",
        "kind": "reviewed-source-inspection",
        "recorded_at": "2026-08-26T12:28:05-05:00",
        "reference": "/etc/kyri/trust/evidence/capability-package/CPKG-0001-verification.yaml" }
    ],
    "expiration": null,
    "history_reference": "TREC-000002",
    "id": "TDEC-000002",
    "lineage_id": "TLIN-000003",
    "previous_state": "unknown",
    "provenance": {},
    "reason": "<see §12 — the decision reason, verbatim>",
    "record_id": "TREC-000002",
    "requested_state": "trusted",
    "resulting_state": "trusted",
    "revokes_record_id": null,
    "scope": {
      "permitted_capabilities": ["CAPDEF-0001"],
      "permitted_data_classifications": ["internal"],
      "permitted_operations": ["execute"],
      "permitted_targets": ["HOST-0001"],
      "scope_id": "TSCOPE-000002",
      "subject_type": "capability-package",
      "validity_end": null,
      "validity_start": null
    },
    "subject_id": "CPKG-0001",
    "supersedes": null,
    "verification_details": {
      "comparison_source": "reviewed-governed-artifact-authority",
      "observed_value_reference": "/var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0.manifest.json",
      "performed_at": "2026-08-26T12:28:05-05:00",
      "performed_by": "primary-platform-operator",
      "subject_property": "capability-package-artifact-identity"
    },
    "verification_method": "reviewed-source-inspection"
  },
  "lineage": {
    "created_at": "2026-08-26T12:28:05-05:00",
    "current_decision_id": "TDEC-000002",
    "current_state": "trusted",
    "first_decision_id": "TDEC-000002",
    "id": "TLIN-000003-v0001",
    "last_changed_at": "2026-08-26T12:28:05-05:00",
    "lineage_id": "TLIN-000003",
    "lineage_type": "subject-decision",
    "prior_decision_ids": [],
    "root_authority_id": "TAUTH-000001",
    "subject_id": "CPKG-0001",
    "subject_type": "capability-package",
    "supersedes_lineage_id": null,
    "terminated": false,
    "termination_reason": null,
    "version": 1
  },
  "record": {
    "authority_id": "TAUTH-000001",
    "created_at": "2026-08-26T12:28:05-05:00",
    "decision_id": "TDEC-000002",
    "domain": "capability-package",
    "expiration": null,
    "expires_at": null,
    "fingerprint": "sha256:703d15ff2f74f071efde0448f4e4f51af9ddd8c6059aba0a1b81726b1e27b8f0",
    "id": "TREC-000002",
    "lineage_id": "TLIN-000003",
    "provenance": {},
    "record_id": "TREC-000002",
    "scope": {
      "permitted_capabilities": ["CAPDEF-0001"],
      "permitted_data_classifications": ["internal"],
      "permitted_operations": ["execute"],
      "permitted_targets": ["HOST-0001"],
      "scope_id": "TSCOPE-000002",
      "subject_type": "capability-package",
      "validity_end": null,
      "validity_start": null
    },
    "state": "trusted",
    "subject_fingerprint": "sha256:46594a1674a8201519895e3b6b765edd19f5f21a44fd272610a35c11282f8449",
    "subject_id": "CPKG-0001",
    "subject_identifier": "CPKG-0001",
    "subject_type": "capability-package",
    "trust_authority_id": "TAUTH-000001"
  }
}
```

### The mutation is not repeatable — verified, not assumed

After success, the same command was **not** re-run. A read-only `--preflight`
against the post-mutation store confirms the Trust plane itself refuses a
second decision:

```
$ python3 -m tools.trust.cli create-decision --preflight ... ; echo EXIT=$?
trust: transition 'trusted' -> 'trusted' is refused: no rule permits 'trusted'
       to become 'trusted'; the transition table is code-owned and this pair is absent
EXIT=2
```

This is a favourable safety property worth recording: a duplicate standing for
`CPKG-0001` cannot be produced by accidentally repeating the ceremony. The
refusal comes from the code-owned transition table, not from an operator check.

---

## 9. Phase 3 — post-write validation

```
$ python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
{
  "counts": { "audit": 4, "authority": 1, "decision": 2,
              "evidence": 7, "lineage": 3, "record": 2 },
  "problems": [],
  "store_root": "/var/lib/kyri/trust",
  "valid": true
}
```

| Required | Observed | Result |
|---|---|---|
| `valid: true` | `true` | PASS |
| `problems: []` | `[]` | PASS |
| `authority: 1` | 1 | PASS |
| `record: 2` | 2 | PASS |
| `decision: 2` | 2 | PASS |
| `evidence: 7` | 7 | PASS |
| `scope: 2` | 2 (sequence) | PASS — see note |
| `lineage: 3` | 3 | PASS |
| `audit: 4` | 4 | PASS |

**Note on `scope: 2`.** `scope` is not a stored record directory in this store —
`TrustStore.record_dirs` has no `scope` entry, so `validate-store` counts cannot
report one. A scope is carried *inside* its record and decision. The required
value was therefore verified as the sequence (`sequences/scope.seq == 2`) and
`TSCOPE-000002` was confirmed present in both `TREC-000002.scope.scope_id` and
`TDEC-000002.scope.scope_id`. This is a reporting-shape observation, not a
defect; flagged in §19 for the reviewer.

### Sequences after the mutation — each advanced by exactly one

```
audit = 4   authority = 1   decision = 2   evidence = 7
lineage = 3   record = 2    scope = 2
```

---

## 10. Allocated identities

All six exist on disk and were verified individually:

```
PASS  TREC-000002.yaml          sha256 c89c5d53ec6c7b51fd7e10b11465d9816def0881626025d51015fcbf2893a5c5
PASS  TDEC-000002.yaml          sha256 02906e66370dfe158d45798a1eba64b0355ed58854dd4a868fc3dda1af96c094
PASS  TEVID-000007.yaml         sha256 1e8a592b806cdce6753b29ad1a2422a337f2f90d89e9026a42ea223258630f71
PASS  TLIN-000003-v0001.yaml    sha256 34c867ce2c1ed14c141e8e00385261e00ed9cd0dc369b70a2b66fab3fa5b8361
PASS  TAUDIT-000004.yaml        sha256 966210775a3cf78bcda42b0949b37bca087fbab23df75c81769fd740e2196c4c
PASS  TSCOPE-000002             carried in both TREC-000002 and TDEC-000002
```

### Append-only proof

Every file in the store was digested before and after the mutation and compared:

```
records changed  : NONE
records removed  : NONE
files added      : ./audit/TAUDIT-000004.yaml
                   ./decisions/TDEC-000002.yaml
                   ./evidence-references/TEVID-000007.yaml
                   ./lineages/TLIN-000003-v0001.yaml
                   ./records/TREC-000002.yaml
sequences bumped : audit, decision, evidence, lineage, record, scope
stray .*.tmp     : none
```

Not one pre-existing record was altered or removed. `TAUTH-000001`,
`TREC-000001`, `TDEC-000001`, `TEVID-000001..000006`, `TLIN-000001`,
`TLIN-000002` and `TAUDIT-000001..000003` are all byte-identical to their
S5-A0 state.

---

## 11. Canonical record summaries

### TREC-000002 — the trust record

```yaml
record_id            : TREC-000002
subject_id           : CPKG-0001
subject_identifier   : CPKG-0001
subject_type         : capability-package
domain               : capability-package
state                : trusted
decision_id          : TDEC-000002
lineage_id           : TLIN-000003
authority_id         : TAUTH-000001
trust_authority_id   : TAUTH-000001
created_at           : 2026-08-26T12:28:05-05:00
expiration           : null
expires_at           : null
provenance           : {}
fingerprint          : sha256:703d15ff2f74f071efde0448f4e4f51af9ddd8c6059aba0a1b81726b1e27b8f0
subject_fingerprint  : sha256:46594a1674a8201519895e3b6b765edd19f5f21a44fd272610a35c11282f8449
scope:
  scope_id                       : TSCOPE-000002
  subject_type                   : capability-package
  permitted_capabilities         : [CAPDEF-0001]
  permitted_operations           : [execute]
  permitted_data_classifications : [internal]
  permitted_targets              : [HOST-0001]
  validity_start                 : null
  validity_end                   : null
```

### TDEC-000002 — the decision

```yaml
decision_id          : TDEC-000002
subject_id           : CPKG-0001
previous_state       : unknown
requested_state      : trusted
resulting_state      : trusted
actor / actor_authority_id : TAUTH-000001
approval_source      : named-operator      # committed default, as predicted in S5-A0
decided_at           : 2026-08-26T12:28:05-05:00
record_id            : TREC-000002
history_reference    : TREC-000002
lineage_id           : TLIN-000003
supersedes           : null
revokes_record_id    : null
expiration           : null
provenance           : {}
verification_method  : reviewed-source-inspection
verification_details :
  subject_property         : capability-package-artifact-identity
  observed_value_reference : /var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0.manifest.json
  comparison_source        : reviewed-governed-artifact-authority
  performed_by             : primary-platform-operator
  performed_at             : 2026-08-26T12:28:05-05:00
decision_fingerprint : sha256:525ae4f35dfc142004626e55be9b15ee888cb3fd02d1a13dc5c0dd5be237b8da
scope                : identical to TREC-000002.scope (TSCOPE-000002)
evidence             : [TEVID-000007]
```

### TEVID-000007 — the cited Trust Evidence

Stored exactly as cited, under the identity that was cited. The Trust plane
refuses to record a citation under a different identity than the operator
supplied.

```yaml
evidence_id : TEVID-000007
id          : TEVID-000007
kind        : reviewed-source-inspection
recorded_at : '2026-08-26T12:28:05-05:00'
reference   : /etc/kyri/trust/evidence/capability-package/CPKG-0001-verification.yaml
```

The referenced evidence file is unchanged at `bd9a5597…60ef4`.
`TEVID-000001..000006` were untouched.

### TSCOPE-000002 — the scope

Carried identically inside both `TREC-000002` and `TDEC-000002`:

```yaml
scope_id                       : TSCOPE-000002
subject_type                   : capability-package
permitted_capabilities         : [CAPDEF-0001]
permitted_operations           : [execute]
permitted_data_classifications : [internal]
permitted_targets              : [HOST-0001]
validity_start                 : null
validity_end                   : null
```

### TLIN-000003 — the lineage

A new lineage, version 1. Stored as `lineages/TLIN-000003-v0001.yaml`; a lineage
advances by writing a new version rather than editing the previous one.

```yaml
lineage_id            : TLIN-000003
id                    : TLIN-000003-v0001
version               : 1
lineage_type          : subject-decision
subject_id            : CPKG-0001
subject_type          : capability-package
root_authority_id     : TAUTH-000001
first_decision_id     : TDEC-000002
current_decision_id   : TDEC-000002
prior_decision_ids    : []
current_state         : trusted
created_at            : 2026-08-26T12:28:05-05:00
last_changed_at       : 2026-08-26T12:28:05-05:00
terminated            : false
termination_reason    : null
supersedes_lineage_id : null
```

`TLIN-000001` (root establishment) and `TLIN-000002` (HOST-0001) untouched.

### TAUDIT-000004 — the audit event

```yaml
audit_id            : TAUDIT-000004
id                  : TAUDIT-000004
event_kind          : trust-decision-created
subject_id          : CPKG-0001
lineage_id          : TLIN-000003
actor_authority_id  : TAUTH-000001
occurred_at         : 2026-08-26T12:28:05-05:00
provenance          : {}
related_record_ids  : [TDEC-000002, TREC-000002, TLIN-000003-v0001,
                       lineage-created, trust-decision-created]
fingerprint         : sha256:534b916ffbc99fb39a946d81b1ecbbbc5cb7d426a83b4749a174bc986a3d62eb
reason              : <the decision reason, verbatim — see §12>
```

### Relationship exactness — 27/27 PASS

Verified: record ↔ decision mutual citation; `history_reference`; shared lineage
across record, decision and audit; `decision.evidence[0]` deep-equal to the
stored `TEVID-000007` record; scope identity across record and decision;
`previous_state: unknown` → `resulting_state: trusted`; null `supersedes`,
`revokes_record_id` and `expiration`; lineage first/current decision equality;
`terminated: false`; audit subject and actor.

---

## 12. The decision reason, verbatim

Stored identically in `TDEC-000002.reason` and `TAUDIT-000004.reason`
(1897 characters):

> The operator reviewed the governed Fabric capability-package record CPKG-0001
> in /var/lib/kyri/fabric/capability-packages/CPKG-0001.yaml and confirmed that
> it declares trust domain capability-package and binds the capability
> definition CAPDEF-0001 and the capability contract CCON-0001, both of which
> resolve in the governed Fabric authority, with CCON-0001 naming CAPDEF-0001 as
> its owning definition. The operator read the package manifest published in the
> trusted artifact authority at
> /var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0.manifest.json
> and confirmed that it binds capability_package_id CPKG-0001, capability_id
> CAPDEF-0001, contract_id CCON-0001 and artifact_reference
> tree:kyri-execution-boundary-verification/1.0.0, each equal to the value the
> Fabric record declares. The operator then recomputed the commitment of the
> published tree read-only with the governed inspection algorithm in
> tools/capability/execution/package_contract.py and obtained
> sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e,
> exactly the package_tree_sha256 the manifest records; the single published
> member main.py is byte-identical to
> packages/kyri-execution-boundary-verification/1.0.0/main.py at the publication
> commit 49c27fb63820bcdadc66d8e78f259430c09471da that CPKG-0001 names, so the
> artifact was materialized from the previously reviewed source according to the
> accepted artifact publication ceremony. On that basis CPKG-0001 is admitted as
> a trusted capability package, scoped narrowly to executing CAPDEF-0001 on
> HOST-0001 over internal data. Nothing was staged and nothing was executed.
> This decision establishes package standing only: no absence of
> vulnerabilities, no general code safety, no production workload suitability
> and no cryptographic publisher identity was established, because neither the
> manifest nor the published tree carries a signature.

---

## 13. Record and decision fingerprints

The rehearsal predicted the durable records exactly. This is the strongest
single evidence that the frozen input was used unmodified.

| | S5-A0 predicted | S5-A1 durable | Result |
|---|---|---|---|
| record | `sha256:703d15ff2f74f071efde0448f4e4f51af9ddd8c6059aba0a1b81726b1e27b8f0` | identical | **PASS** |
| decision | `sha256:525ae4f35dfc142004626e55be9b15ee888cb3fd02d1a13dc5c0dd5be237b8da` | identical | **PASS** |
| subject | `sha256:46594a1674a8201519895e3b6b765edd19f5f21a44fd272610a35c11282f8449` | identical | **PASS** |

Additionally, in S5-A0 a disposable copy of the production store was made in
`/tmp` and the frozen input was actually written into it. That fixture write
produced the same six identities and the same two fingerprints, corroborating
the prediction against a real write before production was touched. The fixture
was destroyed in Phase 7.

---

## 14. Phase 5 — Trust adapter and effective scope

Run through the committed Fabric code path, not a hand calculation.

```
verify_trust_record(store, 'TREC-000002', evaluated_at=2026-08-26T12:28:05-05:00,
                    expected_subject_type=admission.PACKAGE_TRUST_DOMAIN)
  status       : verified
  record_id    : TREC-000002
  subject_id   : CPKG-0001
  subject_type : capability-package
  reasons      : ()
  scope        : capabilities ('CAPDEF-0001',)  operations ('execute',)
                 classifications ('internal',)  targets ('HOST-0001',)
                 scope_id TSCOPE-000002  subject_type capability-package

verify_trust_record(store, 'TREC-000001', ..., expected_subject_type=HOST_TRUST_DOMAIN)
  status: verified   subject: HOST-0001   reasons: ()
```

Effective scope computed by the committed helper
`tools.fabric.admission._effective_scope`, with the operator bound built by the
committed `_admission_scope`:

```
_effective_scope(package = TREC-000002 standing,
                 host    = TREC-000001 standing,
                 bound   = operator admission bound)

PASS  permitted_capabilities         = ('CAPDEF-0001',)   converges on 'CAPDEF-0001'
PASS  permitted_operations           = ('execute',)       converges on 'execute'
PASS  permitted_data_classifications = ('internal',)      converges on 'internal'
PASS  permitted_targets              = ('HOST-0001',)     converges on 'HOST-0001'
```

**All four dimensions non-empty. Effective authority: `CAPDEF-0001` / `execute`
/ `internal` / `HOST-0001`.**

This also re-confirms the S5-A0 target-scope ruling against the durable record:
the package grant's `permitted_targets` is what keeps the targets intersection
non-empty. In S5-A0 the negative cases were proven — a package scope naming
`HOST-0002`, or an empty targets tuple, both refuse with
`refused / empty-effective-scope`.

---

## 15. Phase 6 — cross-plane non-mutation proofs

The production mutation affected the Trust plane only.

| Authority | Before (S5-A0) | After (S5-A1) | Result |
|---|---|---|---|
| Fabric `/var/lib/kyri/fabric` | `9cfcc8de…27aa4a` | `9cfcc8de…27aa4a` | **BYTE-IDENTICAL** |
| Artifact `/var/lib/kyri/artifacts` | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence `/var/lib/kyri/evidence` | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |
| `/etc/kyri/trust` | `4822f2ef…b16cd7` | `4822f2ef…b16cd7` | **BYTE-IDENTICAL** |

Individual governed Fabric records, digested separately:

```
capability-definitions/CAPDEF-0001.yaml  f638df9036e2fe879c526d616ba4c4873ab717e2bc454766a79b32ca17857f74
capability-contracts/CCON-0001.yaml      8ada52704d537e81dd8eaa3a1b641c7ea9fd886928461fa75df8cd02e924beea
capability-packages/CPKG-0001.yaml       ff78628e216b1f188fe5448e0d7354fe7c326d6506e9931a003ab337f9bd7b60
capability-hosts/CHOST-0001.yaml         f7ca6fcabe0d446f6cc31f5603df273188a6927c550c44a86965ac706bb3c7aa
```

All four identical to their S5-A0 values.

```
CADV = 0    CINST = 0    CROUTE = 0    CSEL = 0
Fabric sequence files present: capability-contract.seq, capability-definition.seq,
                               capability-host.seq, capability-package.seq,
                               request_identity.lock
No advertisement / instance / route / selection sequence file exists (0 matches).
Staged trees anywhere under /var/lib/kyri : 0
Staging root /var/lib/kyri/staging        : does not exist
```

**Nothing was staged. Nothing was invoked.**

## 16. Trust before / after state

```
before : cf6d651c999716849251f67dd969198d65445e5e63cb688684d218c21beedd5a   1 record
after  : cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39   2 records
```

The store grew by exactly five immutable records and six sequence increments,
with zero modifications to existing content (§10).

## 17. Root Authority state

**Unmounted throughout.** `/mnt/kyri-root` is not a mountpoint and holds zero
entries; `gpg --list-secret-keys` returns nothing. It was never mounted in S5-A0
or S5-A1. The mutation was authorized by the *recorded* root authority
`TAUTH-000001`, whose private material is external to this platform by design —
the record carries only an `external_identity_reference` and evidence
references, never key material.

## 18. Phase 7 — fixture cleanup

Performed only after every production verification above succeeded.

```
before : /tmp/s5-a0-scratch   188K
         (rehearsal scratch: the pre-freeze copies of both frozen files, the
          negative-control fixture bodies, and a disposable copy of the Trust
          store into which a fixture TREC-000002 had been written)
action : rm -rf /tmp/s5-a0-scratch
after  : /tmp/s5-a0-scratch ABSENT
         ls: cannot access '/tmp/s5-a0-scratch': No such file or directory
         residual /tmp/s5-a0* matches : 0
         fixture-store directories    : 0
```

This was disposable rehearsal state only. Removing it was also a safety measure:
the fixture store contained a real-looking `TREC-000002` that must never be
mistaken for, or promoted to, an authority path.

---

## 19. Unexpected findings

Recorded for the reviewer. **None was corrected in this checkpoint.**

**19.1 — The Trust plane does not enforce three properties one might assume it
does.** Demonstrated in S5-A0 with real preflight runs against the live store,
all of which returned `would_accept: true`:

| Fixture body | Trust verdict | Where it actually refuses |
|---|---|---|
| `subject_id: CPKG-9999` (non-existent Fabric record) | **accepts** | `admit_instance` → `trust-subject-mismatch` |
| scope omitting `CAPDEF-0001` | **accepts** | `_effective_scope` → `empty-effective-scope` |
| `trust_scope.subject_type: fabric-node` | **accepts** | `verify_trust_record` → `trust-subject-type-mismatch` |

The third is the sharp edge: because Trust records are immutable, a body with
the wrong `trust_scope.subject_type` would have been written permanently as
`TREC-000002` and only failed later at admission, unfixable except by opening a
new lineage. This is why the S5-A1 pre-write gate checked it explicitly rather
than relying on the plane. It is a **get-it-right-once** property of the
ceremony, not a defect being corrected here — but a reviewer may wish to rule on
whether Trust should validate the scope/record domain agreement at write time.

**19.2 — Idempotence is enforced, and enforced well.** Re-running the ceremony
after success is refused by the code-owned transition table
(`trusted -> trusted` is absent), exit 2, nothing written. Recorded because it
means the ceremony is safe against accidental repetition — a favourable finding.

**19.3 — `validate-store` cannot report a `scope` count.** `scope` is not a
member of `TrustStore.record_dirs`, so the checkpoint's expected
`scope: 2` is verifiable as a sequence value and as the `scope_id` carried
inside the record and decision, but not as a `counts` entry. Reporting-shape
observation; see §23 Q3.

**19.4 — Preflight non-mutation is behavioural, not structural.** See §7. The
guarantee rests on the `rehearsing()` context variable short-circuiting before
allocation and write, plus `initialize=False`, rather than on a store object that
refuses writes. It held, and was verified by byte-identity, but a reviewer may
want the stronger structural guarantee.

**19.5 — Evidence of the target-scope composition gap.** While ruling on
`permitted_targets` in S5-A0 it was found that `admit_instance` never compares
the admitting node against `effective_scope["permitted_targets"]`. This is now
carried as an accepted Generation-11 blocker (§20.2).

---

## 20. Generation-11 execution-readiness blockers

Accepted reviewer findings, recorded durably here. **None implemented in S5-A1.**

**20.1 — `CapabilityInstance.advertisement_id` is modeled optional while
`admit_instance` requires it.** The model must be made authoritative and the
field non-optional before CINST. A required input that the schema calls optional
means the schema is not the authority on what a valid instance is.

**20.2 — `admit_instance` must explicitly require the admitted capability host
to belong to `effective_scope["permitted_targets"]`.** Today the targets
dimension is only intersected for non-emptiness
(`tools/fabric/admission.py:597-617`); the node being admitted is never compared
against the composed set, unlike `permitted_capabilities`
(`admission.py:1534`) and `permitted_data_classifications` (`admission.py:1539`).
With a single host the two are indistinguishable; with a second host they are
not. Required eventual tests, at minimum:

```
effective targets HOST-0001  +  admitted HOST-0001   →  accept
effective targets HOST-0001  +  admitted HOST-0002   →  refuse
```

**20.3 — Installed Generation 10 has an incomplete dependency closure.** The
installed Capability runtime requires `tools.fabric`, which Generation 10 did not
install; `tools.capability.fabric_evidence`, `coordinator` and `cli` therefore
cannot import in the installed generation.

**20.4 — Generation 11 should provision the existing `tools.fabric` dependency**
rather than duplicating Fabric logic inside Capability, unless dependency-closure
inspection demonstrates an architectural reason not to.

**20.5 — Fabric `select` lacks genuine read-only preflight.** This must be
corrected before `CSEL-000001` is spent. `create-decision --preflight` is the
model to follow: same evaluation, same store opened read-only, stopping at the
allocation boundary.

---

## 21. Exact final production state

```
Trust store /var/lib/kyri/trust
  valid            : true       problems : []
  authority        : 1          TAUTH-000001
  record           : 2          TREC-000001 (HOST-0001, fabric-node, trusted)
                                TREC-000002 (CPKG-0001, capability-package, trusted)
  decision         : 2          TDEC-000001, TDEC-000002
  evidence         : 7          TEVID-000001 .. TEVID-000007
  lineage          : 3          TLIN-000001, TLIN-000002, TLIN-000003
  audit            : 4          TAUDIT-000001 .. TAUDIT-000004
  scope sequence   : 2          TSCOPE-000001, TSCOPE-000002
  whole-tree digest: cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39

Effective authority (committed _effective_scope):
  CAPDEF-0001 / execute / internal / HOST-0001

Fabric /var/lib/kyri/fabric      9cfcc8de…27aa4a   unchanged
  CAPDEF-0001, CCON-0001, CPKG-0001, CHOST-0001 : 1 each, unchanged
  CADV = 0   CINST = 0   CROUTE = 0   CSEL = 0

Artifact authority               63db66fd…8bec25   unchanged
Platform Evidence authority      227abde8…20984b   unchanged
/etc/kyri/trust                  4822f2ef…b16cd7   unchanged
Staged trees                     0
Root Authority                   unmounted
Repository                       656335f4… , clean at time of ceremony
```

## 22. Actions NOT performed

Stated explicitly so absence cannot be mistaken for omission.

- **No second Trust mutation.** Exactly one `create-decision` write was executed.
  The command was not re-run after success.
- **No regeneration, edit, normalization, reserialization or replacement** of
  either frozen file. Both digests re-verified before and after.
- **No CADV created.** Advertisement count remains 0. CADV was not begun.
- **No CINST, CROUTE or CSEL created.** All remain 0, with no sequence files.
- **No staging.** `resolve_and_stage_package` was never called in S5-A0 or
  S5-A1; the published tree was verified read-only through `inspect_package` on
  a directory descriptor. Zero staged trees exist.
- **No invocation.** Nothing in the package was executed.
- **Root Authority never mounted.** No key material was read, created or copied.
- **No Generation-11 correction implemented.** All five blockers in §20 are
  recorded only.
- **No `sudo`, no root privilege.** Every path written was already owned by the
  invoking operator.
- **No implementation source, test, governance schema, operator input or
  production authority changed by the report commit.** The commit contains this
  file only.
- **No secrets recorded.** This report contains public references and digests
  only: no passphrase, private key, token, credential, session material, or Root
  Authority private content.

## 23. Recommended next checkpoint

**S5-B — capability advertisement (`CADV-0001`).** Both trust standings
`admit_instance` requires now exist, so the next governed step is the
advertisement binding `CPKG-0001` to `CHOST-0001`.

Recommended shape, mirroring what worked here: prepare and freeze the operator
input; run a genuine read-only preflight; obtain independent authorization for a
single mutation; then execute and verify. Before CINST, blockers 20.1 and 20.2
must be resolved, since both bear directly on instance admission.

## 24. Questions requiring independent reviewer ruling

1. **Proceed to S5-B (CADV), or hold** for independent review of `TREC-000002`
   first?
2. **Blocker sequencing.** Blockers 20.1 and 20.2 both gate CINST rather than
   CADV. Confirm that S5-B may proceed with them open, or rule that they must be
   closed first.
3. **Should Trust validate scope/record domain agreement at write time**
   (§19.1)? Today a mismatched `trust_scope.subject_type` is accepted into an
   immutable record and only refused later at admission. A pre-write check would
   have caught it; the ceremony gate did instead.
4. **Should `validate-store` report a `scope` count** (§19.3), or is scope
   correctly regarded as a property of a record rather than a record class?
5. **Should preflight non-mutation be made structural** (§19.4) — a store object
   that cannot write — rather than behavioural?
6. **Report cadence.** This is the first durable checkpoint report under
   `docs/development/reports/eng-0005/`. Confirm one report per checkpoint, and
   whether the S5-0 and S5-A0 checkpoints should be backfilled as reports for
   completeness.

---

## Appendix A — commands executed in S5-A1

Read-only unless marked.

```bash
# Phase 0 — pre-write authority gate
git rev-parse HEAD
git rev-parse --abbrev-ref HEAD
git status --porcelain
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
ls /var/lib/kyri/trust/records/
cd /var/lib/kyri/trust && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum
sha256sum /etc/kyri/trust/inputs/trec-0002-capability-package-cpkg-0001.yaml \
          /etc/kyri/trust/evidence/capability-package/CPKG-0001-verification.yaml
python3 -c "<body gate: 12 assertions over the frozen decision input>"
python3 -c "<next-identity gate: peek_next_id for all six kinds>"
mountpoint /mnt/kyri-root ; gpg --list-secret-keys

# Phase 1 — final production preflight (read-only)
python3 -m tools.trust.cli create-decision --preflight \
  --store-root /var/lib/kyri/trust \
  --input-file trec-0002-capability-package-cpkg-0001.yaml \
  --approved-directory /etc/kyri/trust/inputs

# Phase 2 — THE ONE AUTHORIZED PRODUCTION MUTATION  *** WRITES ***
python3 -m tools.trust.cli create-decision \
  --store-root /var/lib/kyri/trust \
  --input-file trec-0002-capability-package-cpkg-0001.yaml \
  --approved-directory /etc/kyri/trust/inputs

# Phase 3-6 — post-write verification (read-only)
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
python3 -c "<TREC-000002 assertions, fingerprints, 27 relationship checks>"
python3 -c "<verify_trust_record for TREC-000002 and TREC-000001>"
python3 -c "<_effective_scope over both standings and the operator bound>"
<whole-tree digests for fabric, artifacts, evidence, /etc/kyri/trust>
<per-file diff of the Trust store against the S5-A0 baseline>

# Phase 7 — fixture cleanup  *** REMOVES DISPOSABLE SCRATCH ONLY ***
rm -rf /tmp/s5-a0-scratch
```

## Appendix B — provenance chain established for CPKG-0001

The chain the Trust decision rests on, each link mechanically verified in S5-A0
and re-affirmed here:

```
reviewed source commit 49c27fb63820bcdadc66d8e78f259430c09471da
  packages/kyri-execution-boundary-verification/1.0.0/main.py
  blob sha256 683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd
        │  byte-identical (cmp clean); commit is an ancestor of reviewed HEAD
        ▼
published artifact  /var/lib/kyri/artifacts/kyri-execution-boundary-verification/1.0.0/main.py
  sha256 683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd
        │  inspect_package over the tree (1 entry, 8192 bytes)
        ▼
tree commitment  sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
        │  equals manifest.package_tree_sha256
        ▼
manifest  .../1.0.0.manifest.json   sha256 53d4624b5136fbf6a7f5c3d0c577d86419828e0dd6d12c5a031fdeeb64244d4b
  binds CPKG-0001 / CAPDEF-0001 / CCON-0001 / tree:kyri-execution-boundary-verification/1.0.0
        │  all four equal to what the Fabric record declares
        ▼
CPKG-0001  (Fabric)  sha256 ff78628e216b1f188fe5448e0d7354fe7c326d6506e9931a003ab337f9bd7b60
        │  cited by TEVID-000007 → TDEC-000002
        ▼
TREC-000002  trusted  scope CAPDEF-0001 / execute / internal / HOST-0001
```

What this chain does **not** establish, restated: absence of vulnerabilities,
general code safety, production workload suitability, cryptographic publisher
identity, any signature over the manifest or the published tree, and the runtime
behaviour of the entrypoint.
