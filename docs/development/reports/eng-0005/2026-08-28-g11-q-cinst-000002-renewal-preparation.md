# ENG-0005 G11-Q — CINST-000002 Renewal Preparation, Trust Re-evaluation, Live Preflight, and Frozen Operator Input

**Date:** 2026-08-28
**Checkpoint:** G11-Q
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

> ## 🔐 STOPPED AT THE PRIVILEGED BOUNDARY
>
> Every unprivileged step is **done and passing**. Trust was re-evaluated at the
> new instant, the candidate rehearsed, written-equivalent in a second fixture,
> and preflighted against live production with `would_accept: true` — all three
> carrying **one identical request digest**.
>
> **The freeze was not performed.** `/etc/kyri/fabric` is `root:cschott 0750`
> and this session runs as uid 1000; a write probe was refused. The
> sandbox-validated fail-closed operator block is in §11.
>
> **`RESULT=OPERATOR_ACTION_REQUIRED`.** The production `admit-instance` write
> was **not** performed.

---

## 1. Objective and outcome

**Objective.** Prepare the renewed binding `CINST-000002` against the fresh
advertisement `CADV-000003`, under the dependency-bounded admission-window
ruling and the supersession ruling.

**Outcome: OPERATOR_ACTION_REQUIRED.**

- **Trust re-evaluated at the new instant**, not taken as cached — both domains
  `verified`, subjects correspond, scope authorises all four dimensions (§6).
- Every supersession precondition **verified from live authority** before the
  body was written (§5).
- `admitted_until` **read from the live `CADV-000003` record**, not calculated
  (§4, §8) — and the **R17 tail is zero by construction**.
- **30 fixture assertions** pass; the write ran in a **second, independent**
  fixture (§9).
- **Live production preflight**: `would_accept: true`,
  `predicted_record_id: CINST-000002` (§10).
- **One request digest** — `sha256:e57d0427…a5e66f` — across all three (§10.1).
- **Production byte-identical**: structural manifest, content manifest, and every
  authority digest (§12).
- **No source or test change.** `IMPLEMENTATION_COMMIT=NONE`.

**One finding worth the reviewer's attention** (§9.1): the fixture initially
refused, because I built all three advertisements before admitting
`CINST-000001`. R16 correctly rejected an admission against a
by-then-superseded `CADV-000002`. **A fixture must reproduce the production
ceremony's *sequence*, not merely its end state** — the corrected fixture does.

---

## 2. Starting authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | same | PASS |
| HEAD | `f1c4bfea75cd8acf6086fe5e6bb8444424d7abdf` | same | PASS |
| Origin contains HEAD | yes | `origin/arch/eng-0005-execution-transition` | PASS |
| Worktree | clean, nothing staged, nothing untracked | clean | PASS |
| G11-P report | present | present | PASS |
| Fabric | validates | `status: reported`, no defects | PASS |
| Trust | validates | `valid: true`, `problems: []` | PASS |
| Generation 11 | unchanged | 57 objects, 9-file closure | PASS |
| Root Authority | unmounted | unmounted | PASS |

### Live production inventory

```
CAPDEF 1   CCON 1   CPKG 1   CHOST 1
CADV   3   (CADV-000001, CADV-000002, CADV-000003)
CINST  1   CROUTE 1   CSEL 0

capability-advertisement.seq = 3      capability-instance.seq = 1
capability-route.seq         = 1      capability-selection.seq: ABSENT

advertisement_head(CADV-000003) = CADV-000003          <- head
CINST-000002 destination        : ABSENT
/etc/kyri/fabric/cinst-000002.json : ABSENT
```

### Forensic manifests captured

Both kinds, per the G11-P lesson: **structural** (26 entries) *and* **content**
(17 files). A sequence replacement of equal byte length is invisible to the
structural manifest — only the content manifest catches it.

```
Fabric   5de5c28f25526139dc390ca34b324a4711f9f350d62cf2f1e0424240202fd65c
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

---

## 3. Admission-window ruling: dependency-bounded

Applied exactly as ruled:

```
admitted_until = CADV-000003.valid_until = 2026-08-30T16:19:19-05:00
```

**Derived from the live record, not calculated.** The value was read out of
`/var/lib/kyri/fabric/capability-advertisements/CADV-000003.yaml` and asserted
equal to it; **no `admitted_at + 24h` and no `admitted_at + 48h` arithmetic was
performed.**

> *"An admitted binding must not be intentionally authorised beyond the freshness
> window of the advertisement that justified the admission."*

### What this buys, measured

```
admitted_at    2026-08-28T19:29:09-05:00
admitted_until 2026-08-30T16:19:19-05:00
window length  1 day, 20:50:10        <- bounded by the dependency, not fixed

R17 tail (admitted while the advertisement is stale) = 0:00:00  -> ZERO
```

The tail is zero **by construction**, not by luck: the two clocks now end at the
same instant, so there is no interval in which the binding is admitted but ELIG-6
finds its advertisement stale. It also avoids the opposite failure — an
arbitrary early expiry while the governing advertisement is still fresh.

**This is ceremony policy only.** Nothing was encoded — no constant, no schema
restriction, no runtime default, no config setting, no architecture rule.
Durable renewal policy remains future Health Runtime work.

---

## 4. Supersession ruling, verified against live authority

`CINST-000002` **shall supersede `CINST-000001`**. Every precondition
`admit_instance` imposes was checked on the live records **before** the body was
written:

| Precondition | Refusal if unmet | Live observation |
|---|---|---|
| prior record resolves | `unresolved-reference` | `CINST-000001` resolves |
| prior not already superseded | `supersedes-already-superseded` | **no successor exists** |
| prior `lifecycle_state == "admitted"` | `supersedes-not-admitted` | `admitted` |
| same capability | `supersedes-different-capability` | `CAPDEF-0001` |
| same contract | `supersedes-different-contract` | `CCON-0001` |
| same package | `supersedes-different-package` | `CPKG-0001` |

```
CINST-000001 supersedes      = None
_binding_root(CINST-000001)  = CINST-000001
CINST-000001 advertisement_id = CADV-000002   (unchanged by the CADV-000003 write)
```

**`CINST-000002` will nevertheless be a NEW BINDING ROOT**, and §9 proves it in
the fixture. `LIFECYCLE_CATEGORIES = ('withdrawal', 'retirement')`;
`admit_instance` files a supersession as `reason_category="supersession"`, which
is not in that set, so `_binding_root` stops at the successor itself. **That
semantic was not modified.**

---

## 5. Trust re-evaluation at the new instant

**Prior verdicts were not treated as cached authority.** Both standings were
recomputed through the released path (`admission._verified_standing` →
`trust_adapter.verify_trust_record`) at the body's own `evaluated_at`.

```
evaluated_at = 2026-08-28T19:29:09-05:00

TREC-000002 package   status=verified  subject_id=CPKG-0001   domain=capability-package
TREC-000001 host      status=verified  subject_id=HOST-0001   domain=fabric-node
```

Record states and scope windows, read live:

```
TREC-000001  state=trusted  expires_at=None  domain=fabric-node
             scope validity_start=None  validity_end=None
TREC-000002  state=trusted  expires_at=None  domain=capability-package
             scope validity_start=None  validity_end=None
```

The **records** are reused — legitimately, since neither expires and both remain
`trusted`. The **verdict** is recomputed; nothing was carried forward.

### Subject correspondence

```
package standing subject == capability_package_id    True   (CPKG-0001)
host standing subject    == node_identity_reference  True   (HOST-0001)
```

### Effective scope, recomputed at `evaluated_at`

```
permitted_capabilities          ['CAPDEF-0001']
permitted_operations            ['execute']
permitted_data_classifications  ['internal']
permitted_targets               ['HOST-0001']
```

All four dimensions the admission requires are authorised:

```
CAPDEF-0001 in permitted_capabilities              True
execute     in permitted_operations                True
internal    in permitted_data_classifications      True
HOST-0001   in permitted_targets                   True   <- G11-A2: node identity, not CHOST-0001
host declared data_classification                  internal
host verified_resource_profile                     {'architecture': 'x86-64'}
```

**Trust verifies. No STOP condition.** Nothing in Trust was repaired, replaced or
written.

---

## 6. `admission_decision_id` — derived, not copied

| Source | Evidence |
|---|---|
| `CINST-000001` frozen input | `admission_decision_id = "eng-0005-cinst-000001-admission"` |
| `CINST-000001` persisted record | agrees |
| Source constraint | `_text(admission_decision_id, REASON_CONTENT)` — free operator text; **no grammar, no pattern, no schema format** |
| G11-H R18 ruling | *"`admission_decision_id` for CINST-000001 is `eng-0005-cinst-000001-admission`; not a TDEC; no global grammar created here."* |

**Chosen: `eng-0005-cinst-000002-admission`.**

The authority is the convention R18 established — a durable operator-decision
reference of the shape `eng-0005-cinst-<identity>-admission` — applied to the
successor identity. This is **following** the established convention, not
inventing a new semantic, and not blindly copying an identity whose meaning was
specific to the prior ceremony: the reference names *this* admission decision.

**It is not a Trust identifier.** `TDEC-000001` and `TDEC-000002` exist and are
untouched; the field deliberately does not name either.

---

## 7. Field-by-field derivation

| Field | Value | Disposition | Authority, verified live |
|---|---|---|---|
| `request_id` | `g11q-admit-instance-cpkg-0001-chost-0001-cadv-000003-supersedes-cinst-000001` | **new** | convention `<checkpoint>-<operation>-<subjects>`, with the supersession named as in `g11f`/`g11o` |
| `actor` | `primary-platform-operator` | copied | `CINST-000001.evidence.actor`; `_human_authority` requires text; must not be `CHOST-0001` or `HOST-0001` |
| `approving_authority` | `primary-platform-operator` | copied | required — *"A human decides this"* |
| `recorded_at` / `evaluated_at` / `admitted_at` | `2026-08-28T19:29:09-05:00` | **one fresh instant** | §8 derives why all three may be equal |
| `capability_id` | `CAPDEF-0001` | verified | `CINST-000001.capability_id`; supersession requires the same |
| `capability_package_id` | `CPKG-0001` | verified | same; also the package `CADV-000003` advertises |
| `capability_host_id` | `CHOST-0001` | verified | same; host chain head, `in-service` |
| `contract_id` | `CCON-0001` | verified | `CPKG-0001.contract_id` |
| `satisfied_contract_versions` | `["1.0.0"]` | verified | declared by `CPKG-0001` **and** advertised by `CADV-000003` |
| `verified_resource_profile` | `{"architecture": "x86-64"}` | verified | must **equal** `CHOST-0001.verified_resource_profile` exactly |
| `admission_decision_id` | `eng-0005-cinst-000002-admission` | **new** | §6 |
| `package_trust_record_id` | `TREC-000002` | verified | re-evaluated §5 |
| `host_trust_record_id` | `TREC-000001` | verified | re-evaluated §5 |
| `advertisement_id` | `CADV-000003` | **new** | the current chain head |
| `supersedes` | `CINST-000001` | **new** | §4 |
| `admission_scope` | four dimensions | **derived from current Trust** | recomputed §5, not copied from the prior body |
| `admitted_at` | `2026-08-28T19:29:09-05:00` | fresh | |
| `admitted_until` | `2026-08-30T16:19:19-05:00` | **read from live `CADV-000003`** | §3 |
| `provenance` | `{class, source, recorded_at: 2026-08-28}` | `class`/`source` copied, date fresh | shape unanimous across frozen inputs |

**Deliberately absent:** `endpoint_reference`, `notes` — both optional and absent
from `CINST-000001`'s frozen input.

---

## 8. The exact body, and temporal proof

```json
{
  "request_id": "g11q-admit-instance-cpkg-0001-chost-0001-cadv-000003-supersedes-cinst-000001",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T19:29:09-05:00",
  "evaluated_at": "2026-08-28T19:29:09-05:00",
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
  "admission_decision_id": "eng-0005-cinst-000002-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000003",
  "supersedes": "CINST-000001",
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
  "admitted_at": "2026-08-28T19:29:09-05:00",
  "admitted_until": "2026-08-30T16:19:19-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

```
BODY_SHA256     e0ecb54805c072c6d2c25b2887ab33b1af4214be3b2e63889c14c0b6cf43925d
size            1267 bytes
REQUEST_DIGEST  sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f
```

Formatting: UTF-8 (us-ascii), LF only (**0** carriage returns), two-space indent,
**exactly one** trailing newline. A byte-identical copy was retained for §11's
`cmp`.

### Temporal proof

```
PASS  all instants timezone-aware
PASS  admitted_until > admitted_at
PASS  admitted_at <= evaluated_at
PASS  evaluated_at < admitted_until
PASS  advertisement fresh at evaluated_at  (observed <= eval < valid)
PASS  CADV.observed_at <= admitted_at
PASS  admitted_until == advertisement.valid_until      <-- DEPENDENCY BOUND
```

### Why `recorded_at == evaluated_at == admitted_at` is permitted — derived

`admit_instance` imposes exactly these ordering rules: `admitted_until >
admitted_at`, `admitted_at <= evaluated_at`, `evaluated_at < admitted_until`,
`advertisement.observed_at <= admitted_at`, and
`advertisement.observed_at <= evaluated_at < advertisement.valid_until`.
`recorded_at` is required only to be timezone-aware — **it carries no ordering
constraint**. Setting all three equal satisfies every rule (`x <= x` holds), and
it is what `CINST-000001` did. So this is derived from the rules, not assumed
from precedent.

---

## 9. Fixture rehearsal and independent write

An isolated fixture built **entirely through released governance operations**,
mirroring the production chain `CADV-000001 → CADV-000002 → CADV-000003` with
`CINST-000001` admitted against `CADV-000002`.

```
PASS: the fixture mirrors the production chain CADV-000001..3 + CINST-000001
PASS: CADV-000003 is the advertisement head
PASS: the fixture CADV-000003 window equals production   [2026-08-30T16:19:19-05:00]
PASS: the fixture predicts CINST-000002
PASS: rehearsal outcome is preflight            [preflight/None]
PASS: rehearsal reason is none
PASS: rehearsal names no record
PASS: no instance allocation and no write
PASS: capability-instance.seq remains 1
PASS: CINST count remains 1
PASS: CINST-000001 is unchanged
PASS: Trust is unchanged
      rehearsal request digest: sha256:e57d0427…a5e66f
PASS:   supersession precondition: prior lifecycle_state is admitted
PASS:   supersession precondition: prior not already superseded
PASS:   supersession precondition: same capability / contract / package
```

**A second, independent fixture** for the write, so the rehearsal fixture was
never mutated to prove it:

```
PASS: the identical body is accepted in a second fixture   [accepted/None]
PASS: the written identity is CINST-000002
PASS: the write carries the same request digest as the rehearsal
PASS: the stored record supersedes CINST-000001
PASS: the stored advertisement_id is CADV-000003
PASS: the stored admitted_until equals CADV-000003.valid_until
PASS: CINST-000002 is its own binding root (supersession is not a lifecycle category)
PASS: the predecessor acquires no superseded_by backlink
PASS: the predecessor is otherwise unchanged by the write
PASS: evidence is filed as supersession
PASS: evidence names both trust standings   [TREC-000002, TREC-000001]
PASS: evidence causally references the predecessor and the advertisement
      [CAPDEF-0001, CCON-0001, CPKG-0001, CHOST-0001, CADV-000003, CINST-000001]
PASS: the stored effective scope is the three-way intersection
PASS: lifecycle_state is admitted
```

**30 assertions, all passing.**

### 9.1 A finding: the fixture must reproduce the *sequence*, not the end state

The first fixture build **refused**:

```
inst  outcome=refused  reason=advertisement-record-superseded
```

I had created all three advertisements and *then* admitted `CINST-000001`
against `CADV-000002` — which by that point was superseded by `CADV-000003`.
**R16 rejected it, correctly.** In production the order was
`CADV-000002 → CINST-000001 → CADV-000003`, and the fixture now follows it.

This is worth recording for two reasons. It is **independent live evidence that
G11-H's R16 correction works** — a rule that only fires on a mis-ordered history
fired exactly there. And it is a standing caution for future ceremony fixtures:
reproducing an end state is not the same as reproducing the history that
produced it, and for chain-sensitive rules only the latter is faithful.

---

## 10. Live production preflight

```bash
python3 -m tools.fabric.cli admit-instance --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json --approved-directory <isolated preparation directory>
```

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

**exit 0.** Every required value checked individually:

```
outcome              OK   'preflight'
would_accept         OK   True
predicted_record_id  OK   'CINST-000002'
destination_exists   OK   False
mutated              OK   False
rehearsal_reason     OK   None
request_digest       OK   'sha256:e57d0427…a5e66f'
```

```
capability-instance.seq remains 1     CINST count remains 1
```

### 10.1 One digest across all three

```
fixture rehearsal            sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f
independent fixture write    sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f
live production preflight    sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f
```

The production run executed under `admission.rehearsing()` against the real
stores, so it consulted the real `CADV-000003`, `CINST-000001`, `CHOST-0001`,
`TREC-000001` and `TREC-000002` — and reached the same digest the fixtures did.

---

## 11. Operator freeze — prepared, NOT performed

### The boundary, re-derived from all nine existing inputs

```
/etc/kyri/fabric                    root:cschott  0750
cadv-000001.json  root:cschott 0640   609    ccon-0001.json   root:cschott 0640  1474
cadv-000002.json  root:cschott 0640   671    chost-0001.json  root:cschott 0640  1125
cadv-000003.json  root:cschott 0640   671    cinst-000001.json root:cschott 0640 1211
capdef-0001.json  root:cschott 0640   783    cpkg-0001.json   root:cschott 0640  1147
croute-0001.json  root:cschott 0640   622
```

**Unanimous: `root:cschott`, mode `0640`.** Verified, not trusted.

### Why this checkpoint stopped

```
running as cschott uid=1000
touch /etc/kyri/fabric/.g11q-probe  ->  Permission denied
```

### Sandbox-validated first

With `DEST` redirected, the block reconstructed the bytes to
`e0ecb548…925d`, **byte-identical** to the retained candidate (`cmp` clean),
parsed as JSON, installed at mode `0640`, size **1267**, and **refused on a
second run**. `/etc/kyri/fabric` was never written.

```bash
set -Eeuo pipefail

DEST=/etc/kyri/fabric/cinst-000002.json
EXPECTED=e0ecb54805c072c6d2c25b2887ab33b1af4214be3b2e63889c14c0b6cf43925d

[[ -e "${DEST}" ]] && { printf 'REFUSING: %s already exists\n' "${DEST}" >&2; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11q-admit-instance-cpkg-0001-chost-0001-cadv-000003-supersedes-cinst-000001",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T19:29:09-05:00",
  "evaluated_at": "2026-08-28T19:29:09-05:00",
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
  "admission_decision_id": "eng-0005-cinst-000002-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000003",
  "supersedes": "CINST-000001",
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
  "admitted_at": "2026-08-28T19:29:09-05:00",
  "admitted_until": "2026-08-30T16:19:19-05:00",
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
sudo stat -c '%n %U:%G %a %s' "${DEST}"
sudo python3 -c 'import json;json.load(open("/etc/kyri/fabric/cinst-000002.json"));print("JSON OK")'
```

### Verification to supply back

```
path      /etc/kyri/fabric/cinst-000002.json
owner     root:cschott      mode 0640      size 1267
sha256    e0ecb54805c072c6d2c25b2887ab33b1af4214be3b2e63889c14c0b6cf43925d
JSON      parses
CINST count still 1 ; capability-instance.seq still 1
```

### Post-freeze preflight — **not run**, because the freeze did not happen

```bash
cd /opt/schott-platform
python3 -m tools.fabric.cli admit-instance --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json \
  --approved-directory /etc/kyri/fabric
```

Require `CINST-000002`, digest `sha256:e57d0427…a5e66f`, `would_accept: true`,
`mutated: false`, `destination_exists: false` — **and `cmp` the frozen file
against the reviewed candidate.** Digest equality alone is not the check; byte
identity is.

### The write — ⚠ NOT AUTHORISED BY THIS CHECKPOINT

```bash
# NOT AUTHORISED BY THIS CHECKPOINT.
# Requires reviewer approval and separate operator authorisation.
# This spends CINST-000002 permanently in an append-only store.
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json \
  --approved-directory /etc/kyri/fabric
```

---

## 12. Production no-mutation

| Authority | Before | After | |
|---|---|---|---|
| Fabric | `5de5c28f25526139dc390ca34b324a4711f9f350d62cf2f1e0424240202fd65c` | same | **IDENTICAL** |
| Trust | `cffd362c…fbbc39` | same | **IDENTICAL** |
| Artifact | `30732e2c…6257f` | same | **IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | same | **IDENTICAL** |
| Installed runtime | `80f9dee2…07f5b` | same | **IDENTICAL** |

**Structural manifest:** no change. **Content manifest:** no change — the second
being the one that would catch an equal-length sequence replacement.

```
CADV 3   CINST 1   CROUTE 1   CSEL 0
capability-instance.seq = 1
/etc/kyri/fabric/cinst-000002.json : ABSENT
Root Authority : unmounted
```

**No privileged operation; every command ran as uid 1000.**

---

## 13. Clock state

```
observed at              2026-08-28T19:31:46-05:00

CADV-000003  (head)      2026-08-30T16:19:19-05:00   44h 47m
CINST-000001             2026-08-29T13:46:27-05:00   18h 14m
CINST-000002 (proposed)  2026-08-30T16:19:19-05:00   44h 47m   <- same instant as CADV-000003
```

The proposed binding and its governing advertisement expire together. That is
the dependency bound doing its job.

---

## 14. `CINST-000002` is a new binding root — and the `CROUTE-0002` consequence

Proven in the fixture (§9): `_binding_root(CINST-000002) == CINST-000002`,
because `admit_instance` files a supersession as `reason_category="supersession"`
and `LIFECYCLE_CATEGORIES` contains only `withdrawal` and `retirement`.

**Therefore `CROUTE-0001` cannot route the renewed binding.** It names
`CINST-000001`, and selection reads the *named* candidate with no forward walk
for instances. Once `CINST-000002` exists, the next route must be:

```
CROUTE-0002
    names          CINST-000002
    route_version  2
    supersedes     CROUTE-0001
```

**No route was created here.**

### Route-head hardening — deferred, and not blocking

`ROUTE_HEAD_HARDENING_BEFORE_CROUTE_0002 = NO`. Production has exactly one
route, so `CROUTE-0001` is necessarily its head, and a correctly prepared
`CROUTE-0002 supersedes CROUTE-0001` cannot exercise the G11-K
non-head-predecessor defect.

**Deadline unchanged: mandatory before `CROUTE-0003` (or any later route
supersession) OR ENG-0005 closure, whichever comes first.** The withdrawn-binding
route defect also remains deferred and compensated by selection.

---

## 15. Actions NOT performed

- **`CINST-000002` not written.** `capability-instance.seq` still 1; CINST count
  still 1.
- **`/etc/kyri/fabric/cinst-000002.json` not frozen** — the privileged step (§11).
- **No `CROUTE-0002`, no `CSEL-000001`, no `CADV-000004`.**
- **Nothing withdrawn or retired; no existing governed record modified.**
- **Route-head enforcement not patched; withdrawn-binding routing not patched.**
- **Trust not mutated** — re-evaluated read-only; no record repaired or replaced.
- **Artifact and Platform Evidence not mutated.**
- **Runtime not reinstalled; sudoers untouched; Root Authority not mounted.**
- **No package staged, nothing invoked.**
- **ENG-0006 not begun; no TrustGateway cutover.**
- **No source or test change**; nothing encoded for the dependency-bounded
  window (§3) and no grammar created for `admission_decision_id` (§6).
- **No privileged operation, no `sudo`.** The only `sudo` in this report is
  inside the §11 block, which was **not run**.
- **No secrets recorded.**

---

## 16. Readiness for the separately authorised `CINST-000002` write

**Conditional YES**, in this order:

1. **Reviewer approves** the body in §8, its digests, the dependency-bounded
   window, and the `admission_decision_id` derivation.
2. **Operator freezes** with the §11 block → `root:cschott 0640`, 1267 bytes,
   `e0ecb548…925d`, and supplies the verification back.
3. **Post-freeze preflight** from `/etc/kyri/fabric` — `CINST-000002`, digest
   `sha256:e57d0427…a5e66f`, plus `cmp` proving byte identity.
4. **Then** the write, under separate authorisation.

**Not ready today** solely because step 2 has not happened. The preflight already
passes against live production.

### Timing

`CADV-000003` and the proposed admission both end `2026-08-30T16:19:19-05:00` —
**44h 47m** from this report. That is the real deadline for the remaining chain:
freeze → write `CINST-000002` → `CROUTE-0002` → `CSEL-000001`. Comfortable, but
not unlimited; if it lapses, a further advertisement renewal is required before
any of it.

**A note on the body's frozen instants.** `evaluated_at` is fixed at
`2026-08-28T19:29:09-05:00`, and `admit_instance` judges advertisement freshness
against that value rather than a clock — so the body stays valid for as long as
the reviewed bytes are unchanged. What the wall clock governs is whether the
*resulting binding* is still useful: admitting at, say, hour 40 would produce a
binding with under five hours of life. The reviewer may prefer to regenerate the
body if approval slips materially.

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo` at any point.**

```bash
# Mandatory starting checks
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
git branch -r --contains f1c4bfe
python3 -c "<inspect_records>" ; python3 -m tools.trust.cli validate-store ...
python3 -c "<advertisement_head, CINST-000001 successor/lifecycle/binding-root>"
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )

# Trust re-evaluation at the new instant + dependency-bounded derivation
python3 -c "<_verified_standing x2 at T, _admission_scope, _effective_scope,
             CADV-000003 valid_until read live, temporal rules>"

# admission_decision_id derivation
python3 -c "<CINST-000001 frozen input>" ; grep -n '_text(admission_decision_id' ...

# Body and temporal proof
python3 - <<'PY' ... PY        # one fresh instant; seven temporal assertions
sha256sum <candidate>          # e0ecb548…925d ; 1267 bytes ; LF only ; JSON parses

# Fixture rehearsal + independent second-fixture write
python3 <rehearse-g11q.py> <candidate>                  # 30 assertions

# Live production preflight
python3 -m tools.fabric.cli admit-instance --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file cinst-000002.json --approved-directory <isolated dir>
<structural AND content manifests, before and after>

# Freeze precedent and block validation
stat -c '%n %U:%G %a %s' /etc/kyri/fabric /etc/kyri/fabric/*.json
touch /etc/kyri/fabric/.g11q-probe                      # Permission denied
<heredoc reconstruction in a sandbox; sha256sum; cmp; json.load; re-run refusal>
```

## Appendix B — the candidate, stated once

```
CINST-000002   predicted, NOT written, NOT frozen

  supersedes      CINST-000001     <- admitted, unsuperseded, same cap/contract/package
  advertisement   CADV-000003      <- the current chain head
  binding         CPKG-0001 -> CHOST-0001 for CCON-0001 @ 1.0.0
  trust           TREC-000002 (package) + TREC-000001 (host)
                  RE-EVALUATED at 2026-08-28T19:29:09-05:00, not cached
  scope           CAPDEF-0001 / execute / internal / HOST-0001
  resources       architecture x86-64, exactly the host's verified profile

  admitted_at     2026-08-28T19:29:09-05:00
  admitted_until  2026-08-30T16:19:19-05:00   = CADV-000003.valid_until EXACTLY
                  window 1d 20:50:10 -- dependency-bounded, not a fixed duration
                  R17 tail = 0:00:00 by construction

  BODY_SHA256     e0ecb54805c072c6d2c25b2887ab33b1af4214be3b2e63889c14c0b6cf43925d
  size            1267 bytes
  REQUEST_DIGEST  sha256:e57d04278bac1628b77848d60d97f0139af815ceabd3fd41496e34f834a5e66f
                  ^ ONE digest across fixture rehearsal, independent fixture
                    write, and live production preflight

AND IT IS A NEW BINDING ROOT:
    supersession is not in LIFECYCLE_CATEGORIES, so _binding_root stops at
    CINST-000002 itself -- which is exactly why CROUTE-0002 will be required.
```
