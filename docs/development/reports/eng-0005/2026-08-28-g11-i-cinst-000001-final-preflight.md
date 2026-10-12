# ENG-0005 G11-I — CINST-000001 Final Rehearsal and Operator Freeze Preparation

**Date:** 2026-08-28
**Checkpoint:** G11-I
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

> ## ⏱ TWO CLOCKS, BOTH ABSOLUTE
>
> | Clock | Ends | Margin from report time |
> |---|---|---|
> | **`CADV-000002` validity** — must still be live when the write is submitted | **`2026-08-29T09:24:51-05:00`** | **19h 36m** |
> | **Instance admission window** — the binding's own governed expiry, R17 | **`2026-08-29T13:46:27-05:00`** | 23h 58m |
>
> The **first** clock is the ceremony deadline. `admit_instance` judges
> advertisement freshness against the body's frozen `evaluated_at`, not against
> a wall clock — but the advertisement must be **current and fresh at the moment
> the decision is made**, and a body whose `evaluated_at` sits outside the
> window would be refused as `advertisement-not-fresh`.
>
> **19h 36m is comfortably above the 12-hour threshold**, so this checkpoint
> proceeds to `READY_FOR_OPERATOR_FREEZE`. If freeze and write cannot both
> complete before `09:24:51` tomorrow, publish `CADV-000003` first and
> regenerate — §18.

---

## 1. Objective and outcome

**Objective.** Regenerate the `CINST-000001` candidate under R15–R18, rehearse
it, obtain a genuine read-only production preflight, and freeze the exact bytes
for the operator. Create no CINST, publish no operator input.

**Outcome: READY_FOR_OPERATOR_FREEZE.**

**The gate that stopped G11-G now passes against live production.**

```
outcome            preflight
would_accept       true
rehearsal_reason   null
predicted_record_id CINST-000001
mutated            false
destination_exists false
```

That single line — `would_accept: true` — is what G11-H's R15 correction was
for. In G11-G this same operation returned `would_accept: false` with
`supersedes-different-capability`; the body was admissible then and the
rehearsal could not say so.

- **33 fixture assertions pass** (§10–11), including full preflight/write
  equivalence: same digest, same identity.
- The **targeted R15/R16 regression** re-proves both G11-H boundaries against
  the current lineage (§12).
- The **production preflight digest is byte-identical to the fixture digest** —
  `sha256:7bd24c86…49da1a` — so the rehearsed body and the reviewed body are
  provably one body (§13).
- **Production is byte-identical** across the whole checkpoint (§15).
- **No source change was made or required** (§16).

**`CINST-000001` was not created. Nothing was published to `/etc/kyri/fabric`.**

---

## 2. Accepted G11-H authority

| Object | |
|---|---|
| G11-H report | `docs/development/reports/eng-0005/2026-08-28-g11-h-cinst-preflight-integrity.md` |
| Report commit | `0c31db85ed1eb516ce123fba548b0694f88e8295` |
| Implementation | `a944cd9` (R15 + R16), `4f333c5`, `0fc0693` (pre-existing test corrections) |
| Full validator at `a944cd9` | **95/95**, recorded in G11-H §14 |

**The mandatory full validator was already satisfied for this source.** `git
diff a944cd9..HEAD -- tools/ provisioning/ tests/` is **empty** — everything
since is documentation — so the 95/95 run covers exactly the source this
checkpoint exercises. No new source commit was created to re-run it, as the
brief directs.

R15 and R16, as accepted:

- a first CINST admission preflight now works;
- admission requires the consumed advertisement to be the current head **and**
  fresh;
- non-head → `advertisement-record-superseded`; current-but-expired →
  `advertisement-not-fresh`.

---

## 3. Current production authority

| Gate | Observed | |
|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD | `0c31db85ed1eb516ce123fba548b0694f88e8295` | PASS |
| Worktree | clean | PASS |
| G11-H commits ancestors of HEAD | `4f333c5 0fc0693 a944cd9 0c31db8` — all YES | PASS |
| Installed runtime | **57** objects, 9-file Fabric closure | PASS |
| Write/control-plane modules installed | **none** | PASS |
| CADV / CINST / CROUTE / CSEL | **2 / 0 / 0 / 0** | PASS |
| `capability-instance.seq` | **absent** | PASS |
| `capability-advertisement.seq` | 2 | PASS |
| Trust store | `valid: true`, `problems: []` | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   6428520119fd10e5bcd6f4dd0b3bb99f6fc6181dc5bcfd7f27e8131798219a30
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

---

## 4. `CADV-000002` — current head, and fresh

Head proven through the **real committed helper**, not by reading YAML:

```python
admission.advertisement_head(store, "CADV-000001")  ->  CADV-000002
admission.advertisement_head(store, "CADV-000002")  ->  CADV-000002
```

`CADV-000002` supersedes `CADV-000001` and nothing supersedes it, so it is the
chain head. Under R16 that is now a **mandatory admission precondition**, not
an observation — and it is the reason this checkpoint checks it explicitly
rather than assuming the lineage is unchanged.

```
observed_at   2026-08-28T09:24:51-05:00
valid_until   2026-08-29T09:24:51-05:00
record digest 555f9a8d35c6cbd92ccb3041a6ed2946809f3704d0a320b3d7ae198320722454
```

**Fresh at Phase 0**: 19h 39m remaining. **Fresh at report time**: 19h 36m.

---

## 5. R17 and R18, as applied

**R17 — admission window.** Applied exactly:

```
admitted_at    = evaluated_at = 2026-08-28T13:46:27-05:00
admitted_until =                2026-08-29T13:46:27-05:00
delta          = 1 day, 0:00:00   (exactly 24 hours)
```

**Nothing was encoded in source.** No schema default, no automatic renewal, no
automatic readmission, and — as the ruling requires — **no
`admitted_until <= CADV.valid_until` coupling**. The candidate's admission
window in fact **exceeds** the advertisement's validity by **4h 21m 36s**, which
R17 explicitly permits: the advertisement must be current and fresh when the
decision is made, and the resulting instance then carries its own governed
admission-expiry clock. The two clocks are independent, and §18 explains what
that means operationally.

**R18 — decision reference.** `admission_decision_id` is
`eng-0005-cinst-000001-admission`, replacing the G11-G placeholder
`g11g-admission-approval-cpkg-0001-chost-0001`. It is a durable
operator-decision reference and **not** a Trust identifier. **No TDEC was
created, no grammar was added, and no source was modified** for this
convention — the field remains free operator text held to `_text`.

---

## 6. Trust intersection — derived, not assumed

Both standings verified through the real adapter
(`admission._verified_standing` → `trust_adapter.verify_trust_record`):

```
TREC-000002  package  status=verified  subject_id=CPKG-0001   domain=capability-package
TREC-000001  host     status=verified  subject_id=HOST-0001   domain=fabric-node
```

The effective scope, computed by the real `_effective_scope` over both grants
and the operator's bound:

| Dimension | Effective |
|---|---|
| `permitted_capabilities` | `['CAPDEF-0001']` |
| `permitted_operations` | `['execute']` |
| `permitted_data_classifications` | `['internal']` |
| `permitted_targets` | `['HOST-0001']` |

And the host facts the three scope gates compare against:

```
CHOST-0001.node_identity_reference   HOST-0001      <- G11-A2 compares THIS, never CHOST-0001
CHOST-0001.data_classification       internal
CHOST-0001.verified_resource_profile {'architecture': 'x86-64'}
```

The `admission_scope` in the body is therefore the intersection restated as the
operator's own bound — **verified against the real grants rather than copied
from the previous candidate.**

---

## 7. Timestamp derivation

One clock read at preparation time, frozen into the reviewed bytes. **No G11-G
timestamp was reused.**

```
T = recorded_at = evaluated_at = admitted_at = 2026-08-28T13:46:27-05:00
    admitted_until                            = 2026-08-29T13:46:27-05:00
```

Every temporal rule `admit_instance` enforces, checked at preparation:

| Rule | Result |
|---|---|
| `admitted_until > admitted_at` | **True** |
| `admitted_at <= evaluated_at` | **True** |
| `CADV.observed_at <= evaluated_at < CADV.valid_until` | **True** |
| `CADV.observed_at <= admitted_at` | **True** |
| `evaluated_at < admitted_until` | **True** |
| R17: window is exactly 24h | **True** |
| `admitted_until > CADV.valid_until` — permitted by R17 | True, by 4h 21m 36s |

`recorded_at` is set equal to `evaluated_at`: `admit_instance` requires only
that it be timezone-aware, and the two describe the same operator decision
instant.

---

## 8. Request identity

```
request_id  g11i-admit-instance-cpkg-0001-chost-0001-cadv-000002
```

Derived from the convention every prior Fabric request follows — **operation and
its subjects, never the resulting identity**, which is not minted yet:

```
s4a-admit-subject-fabric-node-host-0001
s5b2-register-advertisement-cpkg-0001-chost-0001
g11f-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000001
```

It names the package, the host and the advertisement consumed, which is exactly
what identifies this first admission.

**Frozen together, and inseparable:** the `request_id`, the bytes, and the
request digest. Changing any field regenerates all three.

---

## 9. The exact candidate body

```json
{
  "request_id": "g11i-admit-instance-cpkg-0001-chost-0001-cadv-000002",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T13:46:27-05:00",
  "evaluated_at": "2026-08-28T13:46:27-05:00",
  "capability_id": "CAPDEF-0001",
  "capability_package_id": "CPKG-0001",
  "capability_host_id": "CHOST-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "verified_resource_profile": {
    "architecture": "x86-64"
  },
  "admission_decision_id": "eng-0005-cinst-000001-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000002",
  "admission_scope": {
    "permitted_capabilities": [
      "CAPDEF-0001"
    ],
    "permitted_operations": [
      "execute"
    ],
    "permitted_data_classifications": [
      "internal"
    ],
    "permitted_targets": [
      "HOST-0001"
    ]
  },
  "admitted_at": "2026-08-28T13:46:27-05:00",
  "admitted_until": "2026-08-29T13:46:27-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

```
BODY_SHA256     b81e828272b3d8256be8a1d418489f9747c1a3b1d6156c4d77145d7d5d826cda
REQUEST_DIGEST  sha256:7bd24c8669e633896d20ef93c68975310ed16253d9939dc2ca2029b36949da1a
```

**`supersedes` is absent** — this is a first admission, which is precisely the
case R15 made rehearsable.

**`verified_resource_profile` claims architecture and nothing else**, because
`admit_instance` requires it to *equal* `CHOST-0001`'s verified profile exactly
and `EVID-000001` establishes exactly one dimension. No CPU, memory or
accelerator dimension is claimed.

---

## 10. Fixture rehearsal

Against isolated copies of the production Fabric and Trust lineages, exercising
the real corrected `admit_instance`.

```
PASS: predicted identity is CINST-000001
PASS: rehearsal outcome is preflight            [preflight/None]
PASS: rehearsal reason is None
PASS: rehearsal names no record
PASS:   -> after rehearsal: nothing allocated   [records=0 seq=False]
      rehearsal request digest: sha256:7bd24c86…49da1a
```

## 11. Fixture write, and equivalence

```
PASS: fixture write is accepted                 [accepted/None]
PASS: written identity == predicted identity    [CINST-000001]
PASS: preflight digest == write digest          [sha256:7bd24c86…49da1a]
```

The resulting record, field by field:

```
PASS: record carries capability_id           = CAPDEF-0001
PASS: record carries contract_id             = CCON-0001
PASS: record carries capability_package_id   = CPKG-0001
PASS: record carries capability_host_id      = CHOST-0001
PASS: record carries advertisement_id        = CADV-000002
PASS: record carries package_trust_record_id = TREC-000002
PASS: record carries host_trust_record_id    = TREC-000001
PASS: record carries admission_decision_id   = eng-0005-cinst-000001-admission
PASS: record carries lifecycle_state         = admitted
PASS: record verified_resource_profile is architecture x86-64 only
PASS: record effective_scope is the three-way intersection
PASS: record admission window is exactly 24 hours (R17)   [1 day, 0:00:00]
PASS: record supersedes is absent
PASS: evidence names both trust standings    [TREC-000002, TREC-000001]
PASS: evidence reason_category is instance-admission
PASS: evidence causally references all five governed inputs
      [CAPDEF-0001, CCON-0001, CPKG-0001, CHOST-0001, CADV-000002]
```

---

## 12. Targeted R15 / R16 regression

Re-proving the two G11-H boundaries against the **current** lineage, rather than
re-running the whole G11-H development exercise:

```
PASS: R15: a first admission with supersedes absent reaches preflight
PASS: R16: a fresh but superseded advertisement refuses as superseded
           [refused/advertisement-record-superseded]
PASS: R16: and is not reported as stale
PASS:   -> superseded advertisement: nothing allocated
PASS: R16: a current but expired advertisement refuses as not fresh
           [refused/advertisement-not-fresh]
PASS: R16: and is not reported as superseded
PASS:   -> expired advertisement: nothing allocated
```

The superseded case is constructed by pushing `CADV-000001`'s `valid_until`
forward in the fixture, so **freshness cannot be what excludes it** — the only
remaining difference is head-ness. The expired case evaluates the real head one
hour past its window. The two refusals stay distinct, which is the whole point
of the R16 vocabulary ruling.

---

## 13. Production preflight

Read-only, from an isolated approved directory. **Nothing was published to
`/etc/kyri/fabric` to obtain it** — `--approved-directory` is operator-named and
containment is enforced against whatever directory is named, so pointing it at
an isolated preparation directory applies the same rule to a tighter root
(established in G11-F §10).

```bash
python3 -m tools.fabric.cli admit-instance --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000001.json --approved-directory <isolated preparation directory>
```

```json
{
  "destination": "/var/lib/kyri/fabric/capability-instances/CINST-000001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "admit-instance",
  "outcome": "preflight",
  "predicted_record_id": "CINST-000001",
  "record_kind": "capability-instance",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:7bd24c8669e633896d20ef93c68975310ed16253d9939dc2ca2029b36949da1a",
  "request_id": "g11i-admit-instance-cpkg-0001-chost-0001-cadv-000002",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

**exit 0.** Every required field matches: `would_accept: true`, `mutated: false`,
`predicted_record_id: CINST-000001`, `destination_exists: false`,
`rehearsal_reason: null`.

**The production preflight digest equals the fixture digest exactly.** That
equality is the cross-check that the body rehearsed in a fixture and the body
evaluated against production are the same body — and it means the real
`CADV-000002`, the real `TREC-000001`/`TREC-000002` and the real `CHOST-0001`
were all consulted, since the operation ran against the production stores under
`admission.rehearsing()`.

**Predicted destination:**
`/var/lib/kyri/fabric/capability-instances/CINST-000001.yaml` — absent.

---

## 14. Predicted identity

```
peek_next_id("capability-instance")  ->  CINST-000001
```

Six digits, derived from the store's own sequence and the allocator's rule.
Read-only: `capability-instance.seq` remains **absent** before and after, and
the allocator was never asked to spend anything.

---

## 15. Production zero-mutation proof

| Authority | Before | After | |
|---|---|---|---|
| Fabric | `6428520119fd10e5bcd6f4dd0b3bb99f6fc6181dc5bcfd7f27e8131798219a30` | same | **BYTE-IDENTICAL** |
| Trust | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | same | **BYTE-IDENTICAL** |
| Artifact | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | same | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | same | **BYTE-IDENTICAL** |
| Installed runtime | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | same | **BYTE-IDENTICAL** |
| `CADV-000001` | `cb2e16c7…e195` | same | **UNCHANGED** |
| `CADV-000002` | `555f9a8d…2454` | same | **UNCHANGED** |

`diff` of the before and after captures: **identical**.

Around the production preflight specifically, both content **and** metadata were
compared — a content-only digest would not notice a sequence file rewritten to
the same value or a lock left behind:

```
fabric content identical  : YES
fabric metadata identical : YES   (per-path size, mtime, mode)
capability-instance.seq   : absent
CINST count               : 0
```

```
CADV = 2      CINST = 0     CROUTE = 0     CSEL = 0
installed runtime         : 57 objects
/etc/kyri/fabric/cinst-000001.json : absent
Root Authority            : unmounted
```

**No privileged operation. Every command ran as uid 1000.**

---

## 16. Source policy

**No source change was made, and none was required.**

```
$ git status --porcelain
(clean, before the report commit)
```

This checkpoint is a ceremony rehearsal against already-accepted G11-H source.
No governed-behaviour correction was combined with it. The mandatory full
validator obligation is satisfied by the G11-H run at `a944cd9` (§2), and no
empty commit was created to re-run it.

---

## 17. Operator freeze block

Destination and metadata **verified, not assumed**:

```
/etc/kyri/fabric                   root:cschott  0750
/etc/kyri/fabric/cadv-000002.json  root:cschott  0640   (and every sibling)
```

Naming convention across all six existing operator inputs is the lowercased
record identity plus `.json` (`capdef-0001.json`, `ccon-0001.json`,
`cpkg-0001.json`, `chost-0001.json`, `cadv-000001.json`, `cadv-000002.json`),
so the destination is **`/etc/kyri/fabric/cinst-000001.json`** at
**`root:cschott 0640`**.

**Validated in a sandbox before being written here.** With `DEST` redirected to
a scratch path, the block reconstructed the bytes to
`b81e828272b3d8256be8a1d418489f9747c1a3b1d6156c4d77145d7d5d826cda`,
**byte-identical to the candidate** (`cmp` clean), installed at mode `0640`, and
refused on a second run because the destination existed. `/etc/kyri/fabric` was
never written.

```bash
set -Eeuo pipefail

DEST=/etc/kyri/fabric/cinst-000001.json
EXPECTED=b81e828272b3d8256be8a1d418489f9747c1a3b1d6156c4d77145d7d5d826cda

[[ -e "${DEST}" ]] && { printf 'REFUSING: %s already exists\n' "${DEST}" >&2; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11i-admit-instance-cpkg-0001-chost-0001-cadv-000002",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T13:46:27-05:00",
  "evaluated_at": "2026-08-28T13:46:27-05:00",
  "capability_id": "CAPDEF-0001",
  "capability_package_id": "CPKG-0001",
  "capability_host_id": "CHOST-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "verified_resource_profile": {
    "architecture": "x86-64"
  },
  "admission_decision_id": "eng-0005-cinst-000001-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000002",
  "admission_scope": {
    "permitted_capabilities": [
      "CAPDEF-0001"
    ],
    "permitted_operations": [
      "execute"
    ],
    "permitted_data_classifications": [
      "internal"
    ],
    "permitted_targets": [
      "HOST-0001"
    ]
  },
  "admitted_at": "2026-08-28T13:46:27-05:00",
  "admitted_until": "2026-08-29T13:46:27-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
BODY

OBSERVED="$(sha256sum "${TMP}" | cut -d' ' -f1)"
[[ "${OBSERVED}" == "${EXPECTED}" ]] || {
  printf 'REFUSING: reconstructed digest %s != reviewed %s\n' "${OBSERVED}" "${EXPECTED}" >&2
  rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

sudo sha256sum "${DEST}"
sudo stat -c '%n %U:%G %a' "${DEST}"
```

It sets strict shell options, refuses an existing destination, reconstructs the
reviewed bytes inline, verifies the digest **before** installing, installs
`root:cschott 0640`, removes the temporary material, and prints the destination
digest and metadata. **It does not run `admit-instance`.**

### Post-freeze production preflight — read-only, run this next

```bash
cd /opt/schott-platform
python3 -m tools.fabric.cli admit-instance --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000001.json \
  --approved-directory /etc/kyri/fabric
```

Expect `would_accept: true`, `mutated: false`,
`predicted_record_id: CINST-000001`, and request digest
`sha256:7bd24c86…49da1a`. **A different request digest means the frozen bytes
are not the reviewed bytes — stop.**

### The write — ⚠ NOT AUTHORISED BY THIS CHECKPOINT

```bash
# NOT AUTHORISED BY THIS CHECKPOINT.
# Requires reviewer approval and separate operator authorisation.
# This spends CINST-000001 permanently in an append-only store.
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000001.json \
  --approved-directory /etc/kyri/fabric
```

---

## 18. Both clocks, and the ceremony margin

```
report time                    2026-08-28T13:48:05-05:00

CADV-000002 validity ends      2026-08-29T09:24:51-05:00   19h 36m remaining
instance admission would end   2026-08-29T13:46:27-05:00   23h 58m remaining
```

**The advertisement clock is the ceremony deadline, and the admission clock is
not.** R17 deliberately decoupled them, so the binding's window outlives the
advertisement by 4h 21m. What that means in practice:

- **Before `09:24:51` tomorrow** the write must be submitted, or
  `admit_instance` will refuse `advertisement-not-fresh` — correctly.
- **After the write**, the instance is admitted for its own 24 hours. During the
  final 4h 21m of that window the advertisement backing it will have lapsed, so
  **ELIG-6 will find the advertisement stale** and the instance will not be
  eligible for selection even though its admission window is still open. That is
  coherent, not a fault: admission and eligibility ask different questions, and
  the remedy is a fresh advertisement, not a longer admission.

**19h 36m is comfortably above the 12-hour threshold**, so `RESULT` is
`READY_FOR_OPERATOR_FREEZE`.

If freeze and write cannot both complete in time: publish
`CADV-000003 supersedes CADV-000002` through the proven G11-F renewal path, then
regenerate this body with fresh timestamps and `advertisement_id: CADV-000003`.
`BODY_SHA256` and `REQUEST_DIGEST` both change; §17's `EXPECTED` and the
post-freeze expected digest change with them. **Do not weaken freshness.**

---

## 19. Actions NOT performed

- **`CINST-000001` not created.** `capability-instance.seq` still absent; the
  sequence was never allocated from.
- **`/etc/kyri/fabric/cinst-000001.json` not published.** The freeze is the
  operator's act, after reviewer approval.
- **No `CADV-000003` created**; `CADV-000001` and `CADV-000002` both unchanged.
- **No CROUTE, no CSEL. No package staged, no capability invoked.**
- **No TDEC created** (R18).
- **No source change** — and no governed-behaviour correction combined with this
  ceremony (§16).
- **No R17 duration default, automatic renewal, automatic readmission, or
  `admitted_until <= CADV.valid_until` coupling encoded anywhere.**
- **Generation 11 not reinstalled**; installed runtime byte-identical.
- **Trust, Artifact and Platform Evidence not mutated.**
- **Root Authority not mounted.**
- **Approved-directory containment not weakened** — the same rule applied to a
  tighter, isolated root.
- **The production preflight was not bypassed.** It was run, and it passed.
- **No privileged operation, no `sudo`.** The only `sudo` in this report is
  inside the §17 block, which was **not run**.
- **No secrets recorded.**

---

## 20. Unresolved findings

1. **Preflight coverage remains narrow.** G11-H added `admit-instance`;
   `select` and `declare-package` were already covered. **Eight write operations
   are still unrehearsed by any test** — `declare-capability`,
   `declare-contract`, `admit-subject`, `create-route`, `withdraw-subject`,
   `refresh-subject`, `withdraw-instance`, `retire-instance`. R15 was one defect
   found in the first of those paths anyone examined.
2. **No durable admission-window policy surface exists.** R17 settles the
   bootstrap value by explicit ruling and deliberately declines to create one.
3. **`data-classification-not-permitted-by-host` remains unreachable** in this
   lineage — both grants carry only `internal`. An artifact of a
   single-classification fabric, not a defect.
4. **Carried forward, unrelated:** the Artifact digest discrepancy (G11-D §18,
   G11-E §18) and the two lagging execution helper modules (G11-E §10.1).

No new finding was discovered in G11-I.

---

## 21. Recommended next checkpoint

**Reviewer approval, then the operator freeze (§17), then the write.**

In order:

1. **Reviewer approves** the body in §9, its digest, and the R17/R18 application.
2. **Operator freezes** `/etc/kyri/fabric/cinst-000001.json` at
   `root:cschott 0640` with the §17 block.
3. **Post-freeze production preflight** from `/etc/kyri/fabric` — confirm
   `would_accept: true` and request digest `sha256:7bd24c86…49da1a`.
4. **The write**, under separate authorisation, spending `CINST-000001`.
5. **Record the result** in a G11-J checkpoint: independent read-only
   verification of the admitted instance, exactly as G11-E did for the
   Generation-11 installation.

Then the remaining Fabric sequence: **`CROUTE-000001`**, and **`CSEL-000001`**
rehearsed through the G11-C selection preflight before the identity is spent.

**Watch the advertisement clock at step 4** (§18).

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo` at any point.**

```bash
# Phase 0 — authority and the timing boundary
date -Iseconds ; <remaining-margin computation>          # 19h 39m, >= 12h
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <each G11-H commit> HEAD
git diff --stat a944cd9 HEAD -- tools/ provisioning/ tests/   # empty
python3 -c "<advertisement_head via the real helper>"    # CADV-000002 is head
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )

# Phase 1 — the Trust intersection, through the real helpers
python3 -c "<_verified_standing x2, _admission_scope, _effective_scope, peek_next_id>"

# Phases 2-3 — the candidate
python3 - <<'PY' ... PY                                   # one clock read, R17 window
sha256sum <candidate>                                     # b81e8282…6cda

# Phases 4-5 — rehearsal, write equivalence, targeted regression
python3 <rehearse-g11i.py> <candidate>                    # 33 assertions

# Phase 6 — genuine read-only production preflight
python3 -m tools.fabric.cli admit-instance --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000001.json --approved-directory <isolated dir>

# Phase 7 — zero mutation
<fabric content AND metadata digests before/after; authority digests diffed>

# Phases 8-9 — freeze conventions and block validation
stat -c '%n %U:%G %a' /etc/kyri/fabric /etc/kyri/fabric/*.json
<heredoc reconstruction in a sandbox; sha256sum; cmp; re-run refusal>
```

## Appendix B — the candidate, stated once

```
CINST-000001   (predicted, not spent)

  binding          CAPDEF-0001 / CCON-0001 @ 1.0.0
                   CPKG-0001  ->  CHOST-0001  (node HOST-0001)

  consumed         CADV-000002    current head AND fresh
                                  ^ both required since R16

  trust            TREC-000002    capability-package  -> CPKG-0001
                   TREC-000001    fabric-node         -> HOST-0001
                   intersected with the operator's bound ->
                     CAPDEF-0001 / execute / internal / HOST-0001

  decided by       primary-platform-operator, approving itself as operator
                   eng-0005-cinst-000001-admission          (R18)

  resources        architecture x86-64, exactly the host's verified profile
                   package requires {} -- satisfied by anything

  window           admitted_at    2026-08-28T13:46:27-05:00  = evaluated_at
                   admitted_until 2026-08-29T13:46:27-05:00  = +24h exactly (R17)

  supersedes       absent -- a FIRST admission, the case R15 made rehearsable

  BODY_SHA256      b81e828272b3d8256be8a1d418489f9747c1a3b1d6156c4d77145d7d5d826cda
  REQUEST_DIGEST   sha256:7bd24c8669e633896d20ef93c68975310ed16253d9939dc2ca2029b36949da1a

  production preflight: would_accept true, mutated false, CINST-000001

  NOT WRITTEN. NOT FROZEN. The advertisement clock runs out 2026-08-29T09:24:51-05:00.
```
