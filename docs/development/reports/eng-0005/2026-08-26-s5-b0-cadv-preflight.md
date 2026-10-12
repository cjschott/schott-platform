# ENG-0005 S5-B0 — Freeze and Rehearse CADV-000001 Capability Advertisement

**Date:** 2026-08-26
**Checkpoint:** S5-B0
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Derive, prepare, freeze and rehearse the first governed capability
advertisement `CADV-000001`, binding the already-governed `CPKG-0001` and
`CHOST-0001`. Do not create `CADV-000001`.

**Outcome: STOPPED before freeze — deliberately, on two independent grounds
that the checkpoint itself designates as stop conditions.**

Everything that does not depend on those two rulings was completed. The
advertisement semantics were derived from committed authority, the candidate
body was prepared and validated through the real code path, the production
preflight returns `would_accept: true` with `predicted_record_id: CADV-000001`,
the rehearsal replays identically three times, fifteen negative controls were
exercised, and every production authority is byte-identical.

The two stop conditions:

1. **No committed authority determines an advertisement validity duration.**
   ADR-0012 states plainly that "**Advertisement freshness windows are
   unenforced** until a runtime exists". The schema and the implementation fix
   the window's *grammar and ordering* but not its *length*. The checkpoint
   instruction is explicit: *"Do not invent a validity duration. If committed
   authority does not determine a defensible validity duration, STOP and request
   reviewer/operator ruling before freezing CADV."* → **§5, question Q1.**

2. **Publication to `/etc/kyri/fabric/` requires root.** The directory is
   `root:cschott 0750`; the invoking identity is `cschott` (uid 1000) and cannot
   write to it. Per instruction, `sudo` was not used and the exact operator
   command is provided instead. → **§11.**

Additionally, S5-B0 discovered **two new Generation-11 blockers** (§16), one of
which bears directly on the validity ruling: `register_advertisement` accepts a
validity window that has **already closed**, permanently consuming an immutable
identity for a claim that can never be fresh. This was proven by writing such a
record into a disposable fixture store.

**No production state was changed. `CADV-000001` remains unspent.**

---

## 2. Starting branch and HEAD

```
repository : /opt/schott-platform
branch     : arch/eng-0005-execution-transition
HEAD       : 55bdfdb65c572daa6b79db5b1bca15f3c4219ddf
             docs(report): record ENG-0005 S5-A1 package trust
worktree   : clean, no untracked files
```

`55bdfdb…` is present in HEAD, as expected. No implementation source changed
during this checkpoint; the only repository change is this report (§18).

## 3. Starting authority

```
Trust  /var/lib/kyri/trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
  valid: true   problems: []
  counts: authority 1, record 2, decision 2, evidence 7, lineage 3, audit 4
  TREC-000001  HOST-0001  fabric-node          trusted
  TREC-000002  CPKG-0001  capability-package   trusted
  effective authority: CAPDEF-0001 / execute / internal / HOST-0001

Fabric /var/lib/kyri/fabric   9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a
  CAPDEF-0001, CCON-0001, CPKG-0001, CHOST-0001 — one each
  CADV = 0    CINST = 0    CROUTE = 0    CSEL = 0
  sequences present: capability-contract, capability-definition,
                     capability-host, capability-package, request_identity.lock
  store ownership: uid 1000, gid 1000 (cschott)

Artifacts /var/lib/kyri/artifacts   63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
Evidence  /var/lib/kyri/evidence    227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Root Authority /mnt/kyri-root       unmounted
```

---

## 4. Phase 0 — CADV semantics derived from committed authority

### 4.1 The model and schema

Normative sources: `platform-model/schemas/capability-advertisement.schema.yaml`
and `tools/fabric/models.py:503-541`.

```
id_pattern           : ^CADV-[0-9]{6}$
mutability           : immutable
update_methods       : none
delete_methods       : none
supersession         : new-record-only
append_only_history  : true

record_class         : claim
confers_trust        : false
confers_eligibility  : false
creates_instance     : false
may_modify_trust_state : false
requires_admitted_subject : true
queryable_after      : admission
unsolicited          : rejected
on_absent            : capability-absent
on_stale             : instance-ineligible
renews_admission     : false
renews_trust         : false
```

**Required fields** (schema `required_fields`, matching the dataclass exactly):

| Field | Type | Source of the value |
|---|---|---|
| `advertisement_id` | `CADV-NNNNNN` | allocated by the store; never supplied |
| `capability_host_id` | `CHOST-NNNN` | operator-declared reference |
| `capability_package_id` | `CPKG-NNNN` | operator-declared reference |
| `contract_id` | `CCON-NNNN` | operator-declared reference |
| `satisfied_contract_versions` | non-empty sequence | must be a subset of the package's declared versions |
| `advertised_resource_profile` | governed resource map | host self-report; must be covered by the host's *verified* profile |
| `observed_at` | tz-aware instant | operator-declared |
| `valid_until` | tz-aware instant | operator-declared; must be `> observed_at` |
| `provenance` | mapping | operator-declared |

**Optional fields:** `supersedes`, `superseded_by`, `notes` — see §16.2, none is
reachable through any released operation.

**Forbidden fields** (schema): `trust_state`, `trusted`, `trust_score`,
`auto_admit`, `auto_enroll`, `auto_approve`, `scope_grant`, `admitted`,
`admission_decision_id`, `route_id`, `priority`, `weight`, `peer_hosts`,
`token`, `secret`, `credential`, `private_key`, `password`, `command`.

### 4.2 Semantic role — claim, not grant, and durable

ADR-0012 §"Capability Advertisement": *"A host's **self-report**: 'I hold
package P, I satisfy these contract versions, my resources are these.' … It
confers no trust, creates no eligibility, and cannot admit anything — including
itself."*

The schema states this as machine-readable fields (`record_class: claim`,
`confers_trust: false`, `confers_eligibility: false`, `creates_instance: false`,
`may_modify_trust_state: false`) *"so that no implementation can treat an
advertisement as anything other than what it is."*

**Durable authority or transient discovery state?** **Durable.** It is
`immutable`, `append_only_history: true`, with `update_methods: none` and
`delete_methods: none`, stored as a record file under
`capability-advertisements/`. ADR-0012 §"Audit" requires *"**Every
advertisement** — what a host claimed about itself, and when"* to be retained.
**An expired advertisement therefore remains a durable historical record**: it
becomes stale for eligibility purposes (`on_stale: instance-ineligible`) but is
never removed or rewritten.

### 4.3 Exact relationships

Established from `register_advertisement` (`tools/fabric/admission.py:1251-1345`):

| Relationship | Mechanism | Direct or derived |
|---|---|---|
| CADV → CPKG | `capability_package_id`, resolved in the store | **direct** |
| CADV → CHOST | `capability_host_id`, resolved; must be the supersession **head** | **direct** |
| CADV → CCON | `contract_id`, resolved; **and** `package.contract_id == contract_id` | **direct**, cross-checked |
| CADV → CAPDEF | **none** — no field exists | **derived**, via CPKG/CCON |
| CADV → Trust records | **none** — `admission_decision_id` and `trust_state` are forbidden fields | **not referenced at all** |

**Resource/profile claims.** Yes — `advertised_resource_profile`, deliberately
named to mark it as a claim. `tools/fabric/models.py:508`: *"The profile here is
*advertised*; the verified one lives on the host record, where it is visibly not
a claim."* It is bounded by `satisfies(claim, host.verified_resource_profile)`
(`admission.py:1313`), so **a self-report can never enlarge what an operator
attested** — but it may claim *less*.

**Availability semantics.** `availability_intent` is a **capability-host** field,
not an advertisement field, and `register_advertisement` never reads it. This is
deliberate — `admission.py:1262-1264`: *"Retaining the claim is not the same as
authority to admit — a draining or withheld machine may still say what it holds,
and nothing may be admitted onto it."*

---

## 5. Validity-window findings — **the first stop condition**

### 5.1 What committed authority DOES determine

| Question | Answer | Normative source |
|---|---|---|
| Are both bounds required? | **Yes.** `observed_at` and `valid_until` are both in `required_fields` and both are non-defaulted dataclass fields. | schema `required_fields`; `models.py:517-518` |
| Timestamp grammar? | ISO-8601 **with a UTC offset**. A naive instant is refused. | `_require_aware` (`models.py:537-538`); `_aware` (`admission.py:1278-1279`); CLI `_instant` |
| Ordering rule? | `valid_until` **must be strictly greater than** `observed_at`. Equal is refused. | `admission.py:1280-1281` → `REASON_WINDOW` = `invalid-validity-window` |
| May `observed_at` equal ceremony time? | **Yes.** Nothing compares `observed_at` to `recorded_at`; the only constraint is the strict ordering above. | `admission.py:1266-1281` |
| Freshness test at consumption? | `observed_at <= instant < valid_until` — half-open, start inclusive, end exclusive. | `eligibility.py:549-554` (ELIG-6) → `REASON_ADVERT_STALE` |
| Do expired advertisements remain durable? | **Yes**, permanently. Stale ≠ absent, and the two are reported differently. | schema `mutability: immutable`, `on_stale`; `eligibility.py:539-541` |

### 5.2 What committed authority does NOT determine

**How long an advertisement should remain valid.** Searched exhaustively across
`docs/`, `tools/`, `platform-model/` and `tests/`:

- **ADR-0012:809** — *"**Advertisement freshness windows are unenforced** until a
  runtime exists, like every other guarantee here."* This is listed under the
  ADR's own consequences/limitations.
- `docs/fabric/capability-lifecycle.md:134` and ADR-0012:488 describe *what
  happens on lapse* ("claim is stale; instance ineligible"), never *when*.
- No default, constant, policy file or configuration key for an advertisement
  TTL exists anywhere in the tree.
- The test suite uses only opaque fixture symbols — `LATER`, `UNTIL`, `YEAR`,
  `STAMP ± timedelta(hours=1)`, `STAMP - timedelta(days=3)`. These exercise
  ordering and staleness branches; **none is normative about duration.**

**Conclusion: committed authority determines the window's grammar and ordering
but not a defensible duration. Per the checkpoint instruction, this is a STOP.**

### 5.3 Renewal semantics — and a complication

The schema says `supersession: new-record-only` and the model carries
`supersedes` / `superseded_by`. However (see §16.2), **neither field is settable
by any released operation** — `register_advertisement` has no parameter for
either. So in this release, "renewal" can only mean:

> **a brand-new `CADV-NNNNNN`, unlinked to the one it replaces.**

It is *not* mutation (forbidden), *not* extension (ADR-0012:447 forbids a host
extending a validity window), and *not* supersession in any recorded sense —
the chain fields exist but cannot be populated. Every renewal therefore consumes
a fresh identity and leaves no machine-readable link to its predecessor.

**This materially affects the duration ruling.** A short window means many
unlinked `CADV` records accumulating with no supersession chain; a long window
means a claim that stays nominally fresh long after the host may have changed.
Both consequences are governance choices, not engineering ones. → **Q1, Q2.**

---

## 6. Eligibility and Trust behaviour — what CADV creation actually consumes

Reported from the implementation, not from what happens later at CINST.

### 6.1 What `register_advertisement` DOES check

In order, from `admission.py:1266-1332`:

| # | Check | Refusal |
|---|---|---|
| 1 | `capability_host_id` is a well-formed CHOST identifier | `invalid` / malformed content |
| 2 | `actor` is non-empty text | `actor-…` |
| 3 | **`approving_authority` must be absent** — a self-report is not an approval | `unexpected-approving-authority` |
| 4 | `recorded_at`, `observed_at`, `valid_until` are tz-aware | naive → unusable |
| 5 | `valid_until > observed_at` | `invalid-validity-window` |
| 6 | `advertised_resource_profile` is a governed resource map | `resource-dimension-not-governed` / malformed |
| 7 | `satisfied_contract_versions` non-empty | `versions-not-declared` |
| 8 | CHOST resolves | `not-found` / `unresolved-reference` |
| 9 | **`actor == capability_host_id`** — a host may advertise only itself | `actor-is-not-the-subject` |
| 10 | CHOST is the supersession **head** (no fork, loop or superseded record) | `host-record-superseded` / chain reasons |
| 11 | CPKG resolves; CCON resolves | `not-found` / `unresolved-reference` |
| 12 | `package.contract_id == contract_id` | `contract-not-of-package` |
| 13 | every advertised version is in the package's declared versions | `versions-not-declared` |
| 14 | `satisfies(claim, host.verified_resource_profile)` | `resource-claim-not-verified` |

### 6.2 What it does **NOT** consume — stated explicitly

| Candidate | Consumed at CADV? | Where it is actually consumed |
|---|---|---|
| **package Trust** (`TREC-000002`) | **NO** | `admit_instance` (`admission.py:1499`) |
| **host Trust** (`TREC-000001`) | **NO** | `admit_instance` (`admission.py:1502`) |
| **effective Trust scope** | **NO** | `admit_instance` → `_effective_scope` (`admission.py:1533`) |
| host **resource profile** | **YES**, as the ceiling on the claim | also re-checked at `admit_instance:1518-1523` |
| package **resource requirements** | **NO** | `admit_instance:1521-1523`; `eligibility.py` ELIG-5 |
| **classification** (`data_classification`) | **NO** | `admit_instance:1538-1541` |
| **location** (`location_class`) | **NO** | not consumed by CADV or CINST |
| **availability intent** | **NO** — deliberately | `admission.py:1262-1264`, by design |

**This is a significant and non-obvious result.** The CLI registers
`register-advertisement` with `needs_trust = False` (`cli.py:83`), so the trust
store is **never opened** for this operation — not in the write path and not in
the rehearsal. The schema's `requires_admitted_subject: true` is enforced
*structurally*: the check is that a `CHOST` record exists and is the current
head. Because `CHOST-0001` could only have been created by `admit_subject`,
which *did* consume `TREC-000001`, admitted-ness is inherited transitively
through the host record rather than re-queried. That is coherent — but it means
**an advertisement would still register if the host's trust were later revoked**,
because nothing re-reads Trust here. Eligibility and `admit_instance` are the
gates that catch it. Recorded as a finding, not a defect: ADR-0012 places the
trust gate at admission by design.

### 6.3 Structural eligibility of CPKG-0001 from CHOST-0001

Proven by the accepting preflight (§10), which ran every check in §6.1:

```
CHOST-0001 exists, is the head, node_identity_reference HOST-0001
CPKG-0001  exists, contract_id CCON-0001, satisfied_contract_versions [1.0.0]
CCON-0001  exists, contract_version 1.0.0, capability_id CAPDEF-0001
package.contract_id == contract_id                             ✓
advertised versions [1.0.0] ⊆ package declared [1.0.0]         ✓
satisfies({architecture: x86-64}, {architecture: x86-64})       ✓
actor CHOST-0001 == capability_host_id CHOST-0001               ✓
```

And separately, the two Trust standings that CINST will require already exist
and compose (carried from S5-A1): `CAPDEF-0001 / execute / internal / HOST-0001`.

---

## 7. Predicted identity mechanism

Proven through the real read-only mechanism, `FabricStore.peek_next_id`, which
reads the sequence and applies the allocator's own candidate rule without
advancing anything:

```python
FabricStore.open_for_read('/var/lib/kyri/fabric', expected_uid=1000, expected_gid=1000)
  .peek_next_id('capability-advertisement')  ->  'CADV-000001'
  .path_for(...)  ->  /var/lib/kyri/fabric/capability-advertisements/CADV-000001.yaml
  destination exists  ->  False
```

**Sequence state:** `sequences/capability-advertisement.seq` **does not exist** —
the expected pre-first-object state. An absent sequence reads as zero, so the
first candidate is 1. Identifier width is six digits (`^CADV-[0-9]{6}$`), giving
`CADV-000001`. **Not allocated.**

---

## 8. Operator-input convention

Derived from the four existing inputs in `/etc/kyri/fabric/`:

```
drwxr-x---  root:cschott  0750   /etc/kyri/fabric/
-rw-r-----  root:cschott  0640   capdef-0001.json
-rw-r-----  root:cschott  0640   ccon-0001.json
-rw-r-----  root:cschott  0640   chost-0001.json
-rw-r-----  root:cschott  0640   cpkg-0001.json
```

Filename convention: **lowercased record identifier + `.json`**. Because CADV
identifiers are six digits, the derived name is **`cadv-000001.json`** — which
matches the conceptual expectation in the checkpoint. Format is JSON (the Fabric
CLI reads JSON; the Trust CLI reads YAML — the two planes differ, and this
follows the Fabric convention).

**Deviation from the existing inputs, and why.** All four existing bodies carry
`actor: primary-platform-operator`, `approving_authority: primary-platform-operator`
and a `description`. The advertisement body must carry **none** of those:

- `actor` must be **`CHOST-0001`** — `admission.py:1291` refuses unless
  `actor == capability_host_id`, because a host advertises only itself.
- `approving_authority` must be **absent** — supplying one is refused as
  `unexpected-approving-authority` (§6.1 check 3).
- `description` is **not a parameter** of `register_advertisement`; including it
  raises `TypeError`, which the CLI reports as *"the decision body does not match
  this operation"*.

---

## 9. Complete proposed body — **CANDIDATE, NOT FROZEN**

`/tmp/s5-b0-scratch/inputs/cadv-000001.json`

```json
{
  "request_id": "s5b-register-advertisement-cpkg-0001-chost-0001",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-26T13:12:47-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": ["1.0.0"],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-26T13:12:47-05:00",
  "valid_until": "2026-08-27T13:12:47-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-26"
  }
}
```

**SHA-256: `9a400d01c48ab5228528d094c6b1985626381dfcc271a2c964aac997bafe2da3`**

> ⚠️ **This body is NOT frozen and MUST NOT be published as-is.** The
> `valid_until` value encodes a 24-hour window chosen **only to make the
> rehearsal executable**. It has **no committed authority** and is not a
> recommendation. It must be replaced by whatever duration the reviewer rules
> (Q1) before freezing, which will change the SHA-256.

### 9.1 Authority for every value

| Field | Value | Normative authority |
|---|---|---|
| `request_id` | `s5b-register-advertisement-cpkg-0001-chost-0001` | operator-declared; follows the `s<stage>-<operation>-<subject>` convention of the four existing inputs |
| `actor` | `CHOST-0001` | **required** by `admission.py:1291` (`actor == capability_host_id`) |
| `approving_authority` | *absent* | **required** absent by `admission.py:1275-1276` |
| `recorded_at` | `2026-08-26T13:12:47-05:00` | operator ceremony instant, America/Chicago (CDT), tz-aware per `_aware` |
| `capability_host_id` | `CHOST-0001` | the governed Fabric host record; the only one that exists |
| `capability_package_id` | `CPKG-0001` | the governed Fabric package record, `trusted` as `TREC-000002` |
| `contract_id` | `CCON-0001` | **derived-and-checked**: `CPKG-0001.contract_id == CCON-0001` (`admission.py:1304`) |
| `satisfied_contract_versions` | `["1.0.0"]` | **derived**: `CPKG-0001.satisfied_contract_versions == ["1.0.0"]`; must be a subset (`admission.py:1307-1309`). Also equals `CCON-0001.contract_version` |
| `advertised_resource_profile` | `{"architecture": "x86-64"}` | token `architecture` and value `x86-64` are the governed vocabulary (`tools/fabric/resources.py` `RESOURCE_FIELDS`: `architecture -> ('token', {'x86-64'})`). Equals `CHOST-0001.verified_resource_profile`, so `satisfies` holds exactly and the claim enlarges nothing |
| `observed_at` | ceremony instant | permitted to equal ceremony time (§5.1) |
| `valid_until` | **UNRULED** | ⚠️ **no committed authority** — see §5.2, Q1 |
| `provenance.class` | `declared` | matches all four existing Fabric inputs |
| `provenance.source` | `docs/decisions/ADR-0012-…md` | the governing ADR, as in all four existing inputs |
| `provenance.recorded_at` | `2026-08-26` | ceremony date |

Every value except `valid_until` is either mechanically derived from an existing
governed record or drawn from a committed vocabulary. **`valid_until` is the
single field lacking authority**, which is precisely why the freeze is stopped.

### 9.2 Scratch validation

The body was validated **through the real code path**, not a re-implementation:
the Fabric CLI's `_decision_body` reader, `INSTANT_FIELDS` coercion, and the
governed `admission.register_advertisement` under `admission.rehearsing()`.
Result: accepted (§10). No separate validator was written.

---

## 10. Production preflight

```
$ python3 -m tools.fabric.cli register-advertisement --preflight \
    --store-root /var/lib/kyri/fabric \
    --expected-uid 1000 --expected-gid 1000 \
    --input-file cadv-000001.json \
    --approved-directory /tmp/s5-b0-scratch/inputs
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
  "request_digest": "sha256:5d069a268e577ed00598331186c34381cd7d98bf42aa5f79e93a31cddec736fe",
  "request_id": "s5b-register-advertisement-cpkg-0001-chost-0001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

All four required conceptual results met: `would_accept: true`, `mutated: false`,
`predicted_record_id: CADV-000001`, `destination_exists: false`.

**Request digest:** `sha256:5d069a268e577ed00598331186c34381cd7d98bf42aa5f79e93a31cddec736fe`
**Request id:** `s5b-register-advertisement-cpkg-0001-chost-0001`

### 10.1 Replay

The operation supports repeatable preflight safely (`open_for_read`, no
allocation, no write). Run **three times**; outputs `diff`-clean — identical in
every field including `request_digest`.

### 10.2 Immediate non-mutation proof

```
CADV count                     : 0
advertisement sequence file    : does not exist
sequences present              : capability-contract, capability-definition,
                                 capability-host, capability-package,
                                 request_identity.lock   (unchanged)

Fabric    9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a  unchanged
Trust     cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39  unchanged
Artifacts 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25  unchanged
Evidence  227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b  unchanged
```

---

## 11. Freeze — **the second stop condition**

**Not performed.** Two independent reasons, either sufficient alone:

1. The body is not ready to freeze — `valid_until` lacks authority (§5.2, Q1).
2. Publication requires root:

```
$ stat -c '%U:%G %a' /etc/kyri/fabric      →  root:cschott 750
$ id -un                                    →  cschott (uid 1000)
$ touch /etc/kyri/fabric/.probe             →  Permission denied
$ [ -e /etc/kyri/fabric/cadv-000001.json ]  →  destination ABSENT
```

`sudo` was **not** used, per instruction.

### 11.1 Exact operator command — *only after Q1 is ruled*

Once the reviewer rules the validity duration, the candidate body must be
regenerated with the ruled `valid_until` (its SHA-256 **will change**), then
published by an operator with root:

```bash
# 1. Confirm the destination is still absent (refuse rather than overwrite).
test ! -e /etc/kyri/fabric/cadv-000001.json || { echo "REFUSE: destination exists"; exit 1; }

# 2. Publish with the derived ownership and mode.
sudo install -o root -g cschott -m 0640 \
     /tmp/s5-b0-scratch/inputs/cadv-000001.json \
     /etc/kyri/fabric/cadv-000001.json

# 3. Verify.
stat -c '%U:%G %a %n' /etc/kyri/fabric/cadv-000001.json
sha256sum /etc/kyri/fabric/cadv-000001.json
```

Expected metadata: `root:cschott 640`. **After publication the SHA-256 must be
re-verified against the reviewed value before the preflight is re-run.** The
current candidate digest `9a400d01…2da3` will be superseded.

---

## 12. Negative controls

All exercised with fixtures and read-only preflight. **Production was never
mutated** — the Fabric digest was `9cfcc8de…27aa4a` before and after.

| # | Control | `would_accept` | outcome / reason |
|---|---|---|---|
| NC-1 | nonexistent CPKG (`CPKG-9999`) | false | `not-found` / `unresolved-reference` |
| NC-2 | nonexistent CHOST (`CHOST-9999`) | false | `not-found` / `unresolved-reference` |
| NC-3 | nonexistent contract (`CCON-9999`) | false | `not-found` / `unresolved-reference` |
| NC-3b | **contract exists but is not the package's** (fixture) | false | `refused` / **`contract-not-of-package`** |
| NC-4 | **entirely-past validity window** | ⚠️ **true** | `preflight` / — **see §16.1** |
| NC-5 | reversed window (`valid_until < observed_at`) | false | `refused` / `invalid-validity-window` |
| NC-5b | zero-length window (`valid_until == observed_at`) | false | `refused` / `invalid-validity-window` |
| NC-6 | ungoverned resource dimension (`availability_intent`) | false | `refused` / `resource-dimension-not-governed` |
| NC-7 | malformed reference (`not-an-identifier`) | false | `not-found` / `unresolved-reference` |
| NC-8 | actor is not the subject (`primary-platform-operator`) | false | `refused` / `actor-is-not-the-subject` |
| NC-9 | approving authority supplied | false | `refused` / `unexpected-approving-authority` |
| NC-10 | version not declared by the package (`2.0.0`) | false | `refused` / `versions-not-declared` |
| NC-11 | ungoverned architecture token (`arm64`) | false | `invalid` / `malformed-operation-content` |
| NC-12 | claim enlarges verified profile (`host_memory_mb: 64000`) | false | `refused` / `resource-claim-not-verified` |
| NC-13 | empty `satisfied_contract_versions` | false | `refused` / `versions-not-declared` |
| NC-14 | naive `valid_until` (no offset) | exit 2 | *"valid_until must carry a timezone offset"* |

**NC-3b required a fixture.** With only one contract in production, a mismatched
`contract_id` can only ever be *unresolvable*, so the true
`contract-not-of-package` branch is unreachable. A disposable copy of the Fabric
store was made in `/tmp`, a second contract `CCON-0002` was declared **in the
fixture only**, and the refusal was then exercised. Reported so the control set
is not read as more complete than a single-contract store can make it.

**NC-11 is a token-vocabulary refusal, not a containment one.** `arm64` is not a
governed `architecture` value (`RESOURCE_FIELDS: architecture -> ('token',
{'x86-64'})`), so it fails resource-map validation before the containment check.
NC-12 exercises the containment path proper.

**Additional controls beyond the required set:** NC-3b, NC-5b, NC-8, NC-9,
NC-10, NC-11, NC-13, NC-14 were added because the implementation exposes refusal
branches the required list did not name.

---

## 13. Before / after digests

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric | `9cfcc8de…27aa4a` | `9cfcc8de…27aa4a` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifacts | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |
| `/etc/kyri/fabric` | 4 inputs | 4 inputs | **unchanged — nothing frozen** |
| `/etc/kyri/trust` | `4822f2ef…b16cd7` | `4822f2ef…b16cd7` | **BYTE-IDENTICAL** |

```
CADV = 0    CINST = 0    CROUTE = 0    CSEL = 0
capability-advertisement.seq : does not exist
Root Authority /mnt/kyri-root : unmounted, 0 entries, 0 secret keys
```

---

## 14. Fixture disposition

A disposable copy of the Fabric store was created at
`/tmp/s5-b0-scratch/fixture-fabric` to exercise NC-3b and to prove the §16.1
finding. It contains a real-looking `CADV-000001` and a fixture `CCON-0002`, and
**must never be promoted to an authority path.** It was removed after the
evidence was extracted; see §19 for the verification.

---

## 15. Generation-11 execution-readiness blockers — carried forward

Unchanged from S5-A1, none implemented:

1. **`CapabilityInstance.advertisement_id` must become non-optional.** It is
   modeled optional while `admit_instance` requires it.
2. **`admit_instance` must require the admitted host to belong to
   `effective_scope["permitted_targets"]`.** Today the targets dimension is only
   intersected for non-emptiness (`admission.py:597-617`); the node is never
   compared to the composed set, unlike capabilities (`:1534`) and
   classifications (`:1539`). Required tests:
   `effective targets HOST-0001 + admitted HOST-0001 → accept`;
   `effective targets HOST-0001 + admitted HOST-0002 → refuse`.
3. **Installed Capability runtime lacks `tools.fabric` dependency closure.**
   Generation 10 did not install it, so `tools.capability.fabric_evidence`,
   `coordinator` and `cli` cannot import in the installed generation.
4. **G11 should package the existing `tools.fabric`** rather than duplicate
   Fabric logic inside Capability, unless dependency inspection disproves it.
5. **`select` needs genuine read-only preflight before `CSEL-000001` is spent.**

## 16. New blockers and findings discovered in S5-B0

### 16.1 — NEW BLOCKER: an already-closed validity window is accepted

`register_advertisement` checks only `valid_until > observed_at`
(`admission.py:1280-1281`). It never compares the window to `recorded_at` or to
any present instant. A body whose window closed weeks ago is accepted and
**written as a permanent, immutable record**.

Proven in the fixture store (never in production):

```
body     : observed_at 2026-08-01T00:00:00-05:00
           valid_until 2026-08-02T00:00:00-05:00
           recorded_at 2026-08-26T13:12:47-05:00
preflight: would_accept = true
write    : accepted, record CADV-000001 created in the FIXTURE store

ELIG-6 requires  observed_at <= instant < valid_until
at registration: 2026-08-01 <= 2026-08-26 < 2026-08-02  →  False
```

The window had closed **24 days before the record was written**. No instant at
or after registration can ever satisfy ELIG-6, so the record is permanently
incapable of making any instance eligible — yet it has consumed `CADV-000001`
irreversibly, in an append-only store with `update_methods: none` and
`delete_methods: none`.

**Recommended correction (do not implement here):** refuse when
`valid_until <= recorded_at`, with a distinct reason such as
`validity-window-already-closed`, separate from `invalid-validity-window` so an
operator can tell "you reversed the bounds" from "you registered a dead claim".
Tests should cover: window entirely past → refuse; window straddling
`recorded_at` → accept; window entirely future → accept (a host may legitimately
pre-announce); `valid_until == recorded_at` → refuse.

This is a **direct consequence of the unruled duration** and should be settled
together with Q1.

### 16.2 — NEW BLOCKER: `supersedes`, `superseded_by` and `notes` are unreachable

All three are declared on `CapabilityAdvertisement` and in the schema's
`optional_fields`, but **no released operation can set any of them**:

```
model fields  : advertised_resource_profile, advertisement_id, capability_host_id,
                capability_package_id, contract_id, evidence, notes, observed_at,
                provenance, satisfied_contract_versions, superseded_by,
                supersedes, valid_until
NOT settable  : notes, superseded_by, supersedes
```

`register_advertisement` has no parameter for them, and no other operation in
`tools/` supersedes an advertisement. The schema declares
`supersession: new-record-only`, but the fields that would *record* a
supersession cannot be populated — so a "renewed" advertisement has no
machine-readable link to the one it replaces, and eligibility cannot distinguish
a renewal from an unrelated new claim.

Either the write path should accept `supersedes` (with the usual head/fork
checks the other record kinds get), or the fields should be removed from the
model as unreachable. Leaving them is a schema that describes a capability the
platform does not have.

### 16.3 — Finding (not a blocker): Trust is not re-read at advertisement

Recorded in §6.2. `register-advertisement` is registered with
`needs_trust = False`, so no trust store is opened. Admitted-ness is inherited
transitively through the existence of the `CHOST` record rather than re-queried,
which means an advertisement would still register after the host's trust were
revoked. ADR-0012 places the trust gate at admission by design, and eligibility
plus `admit_instance` do catch it — so this is reported as an architectural
consequence for the reviewer to confirm, not as a defect.

### 16.4 — Finding: the two planes use different operator-input formats

Trust operator inputs are YAML (`/etc/kyri/trust/inputs/*.yaml`); Fabric operator
inputs are JSON (`/etc/kyri/fabric/*.json`). Both are read through a contained
approved-directory reader. Noted so the difference is a recorded decision rather
than a surprise at the next ceremony.

---

## 17. Actions explicitly NOT performed

- **`CADV-000001` was NOT created.** CADV count is 0; the identity is unspent;
  `capability-advertisement.seq` does not exist.
- **The body was NOT frozen** to `/etc/kyri/fabric/cadv-000001.json`. The
  destination remains absent.
- **`sudo` was NOT used**, and no root-owned path was written.
- **No CINST, CROUTE or CSEL** created — all remain 0.
- **No package staged.** `resolve_and_stage_package` was never called; zero
  staged trees exist.
- **Nothing invoked.**
- **Trust not altered** — digest identical, still 2 records, `valid: true`.
- **Platform Evidence not altered.** **Artifact authority not altered.**
- **Root Authority not mounted.**
- **Generation 11 not opened**; no G11 correction implemented.
- **No implementation, test or schema change.** The report commit contains this
  file only.
- **No secrets recorded** — this report contains public references and digests
  only.

## 18. Repository changes

No implementation change was expected and none was made. Advertisement behaviour
has **no defect that prevents safe rehearsal** — the rehearsal completed
cleanly. The two findings in §16.1 and §16.2 are correctness gaps that affect
what may safely be *frozen and written*, not the ability to rehearse, and per
instruction they are **reported, not repaired**, in this checkpoint.

This checkpoint commits exactly one file: this report.

## 19. Recommendation

**Do not freeze or create `CADV-000001` until Q1 is ruled**, and consider ruling
§16.1 at the same time — the two are entangled, and §16.1 means an unlucky
duration choice is not merely suboptimal but permanently consumes the first
advertisement identity on a record that can never be used.

Suggested sequence:

1. Reviewer rules the validity duration (Q1) and the renewal model (Q2).
2. Reviewer rules whether §16.1 must be corrected **before** `CADV-000001`
   (recommended) or may be deferred to G11.
3. Regenerate the candidate body with the ruled `valid_until`; re-report its
   SHA-256.
4. Operator publishes with the §11.1 command; SHA-256 re-verified.
5. Re-run the preflight against the frozen input; expect
   `would_accept: true`, `CADV-000001`.
6. Independent authorization for the single `register-advertisement` write.
7. **Stop.** Per the accepted reviewer ruling, CINST does not follow CADV in
   this checkpoint sequence — the Generation-11 blockers are addressed first.

## 20. Questions requiring independent reviewer ruling

1. **What validity duration should `CADV-000001` carry?** No committed authority
   determines one, and ADR-0012:809 explicitly leaves freshness windows
   unenforced. The rehearsal used 24 hours purely to be executable; that number
   has no standing. **Blocking the freeze.**
2. **What does renewal mean operationally** (§5.3)? Given §16.2, a renewed
   advertisement today is an unlinked new `CADV`. Is that the intended model for
   this release, or should `supersedes` become settable first?
3. **Must §16.1 (already-closed window accepted) be corrected before
   `CADV-000001` is written?** Writing the first advertisement into a store
   whose write path cannot reject a dead-on-arrival claim is a permanent act.
4. **Should §16.2 be resolved by making the fields settable, or by removing
   them** from the model as unreachable?
5. **Confirm §16.3** — that Trust is intentionally not re-read at advertisement
   registration, admitted-ness being inherited through the `CHOST` record.
6. **Is `{"architecture": "x86-64"}` the right advertised profile**, or should
   the host advertise `{}`? Claiming exactly the verified profile is the faithful
   self-report and passes containment exactly; `{}` would claim nothing and also
   pass. The former is recommended and was rehearsed.

---

## Appendix A — commands executed

All read-only against production. Fixture writes went to `/tmp` only.

```bash
# Starting authority
git rev-parse HEAD ; git status --porcelain
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
<whole-tree digests for trust, fabric, artifacts, evidence>

# Phase 0 — semantics from committed authority
cat platform-model/schemas/capability-advertisement.schema.yaml
sed -n '503,541p'   tools/fabric/models.py          # CapabilityAdvertisement
sed -n '1249,1345p' tools/fabric/admission.py       # register_advertisement
sed -n '1,290p'     tools/fabric/cli.py             # CLI, preflight semantics
grep -n "def satisfies" -A35 tools/fabric/resources.py
grep -rn -i "valid_until|freshness|advertisement" docs/ tools/ platform-model/ tests/
python3 -c "import inspect; ... register_advertisement signature"

# Identity, read-only
python3 -c "FabricStore.open_for_read(...).peek_next_id('capability-advertisement')"

# Preflight (×3, identical)
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000001.json --approved-directory /tmp/s5-b0-scratch/inputs

# Negative controls NC-1 .. NC-14 (same command, fixture bodies)
# NC-3b and the §16.1 proof, against the FIXTURE store only:
cp -a /var/lib/kyri/fabric /tmp/s5-b0-scratch/fixture-fabric
python3 -m tools.fabric.cli declare-contract --store-root /tmp/.../fixture-fabric ...
python3 -m tools.fabric.cli register-advertisement --store-root /tmp/.../fixture-fabric ...

# Freeze preconditions (refused, as expected)
stat -c '%U:%G %a' /etc/kyri/fabric
touch /etc/kyri/fabric/.probe        # Permission denied — sudo NOT used

# Fixture cleanup
rm -rf /tmp/s5-b0-scratch
```

## Appendix B — the eligibility conditions an advertisement participates in

From `tools/fabric/eligibility.py`, for reference when ruling Q1:

```
ELIG-5  resources : satisfies(package.resource_requirements,
                              host.verified_resource_profile)
ELIG-6  advertised: the instance names an advertisement; it resolves;
                    observed_at <= instant < valid_until
                    otherwise  advertisement-not-fresh  (stale, not absent)
```

An advertisement outside its window makes the *instance* ineligible. It does not
revoke trust, does not lapse the admission, and is never deleted —
ADR-0012:492: *"a fresh advertisement does not revive an expired admission or an
expired trust record."*
