# ENG-0005 G11-O — CADV-000003 Renewal Preparation, Live Preflight, and Frozen Operator Input

**Date:** 2026-08-28
**Checkpoint:** G11-O
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

> ## 🔐 STOPPED AT THE PRIVILEGED BOUNDARY
>
> Every unprivileged step is **done and passing**. The candidate is derived,
> rehearsed, written-equivalent in a second fixture, and preflighted against
> live production with `would_accept: true` — all three carrying **one identical
> request digest**.
>
> **The freeze was not performed.** `/etc/kyri/fabric` is `root:cschott 0750`
> and this session runs as uid 1000; a write probe was refused. The fail-closed
> operator block is in §10, validated byte-for-byte in a sandbox.
>
> **`RESULT=OPERATOR_ACTION_REQUIRED`.** The production `register-advertisement`
> write was **not** performed and is not authorised by this checkpoint.

---

## 1. Objective and outcome

**Objective.** Prepare the production renewal advertisement `CADV-000003` under
the reviewer's 48-hour window ruling: derive, rehearse, preflight, freeze.

**Outcome: OPERATOR_ACTION_REQUIRED** — everything short of the privileged
install is complete.

- Every field **derived and verified against live authority**, not trusted (§4).
- `CADV-000002` confirmed the **current chain head** through the released helper
  (§4.1) — the R4 precondition for a lawful renewal.
- **Temporal proof**: all five assertions pass, window exactly 48 hours (§6).
- **22 fixture assertions** pass; the write ran in a **second, independent**
  fixture so the rehearsal fixture was never mutated to prove it (§7).
- **Live production preflight**: `would_accept: true`,
  `predicted_record_id: CADV-000003`, `mutated: false` (§8).
- **One request digest** — `sha256:b86457da…282c5d` — across fixture rehearsal,
  fixture write, and production preflight (§8.1).
- **Production byte-identical** in content, metadata, and per-path structure
  (§9).
- **No source or test change.** `IMPLEMENTATION_COMMIT=NONE`.

---

## 2. Starting authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | same | PASS |
| HEAD | `4f4d44fc947cac87cdcbd5ae64482e6a8cf29890` | same | PASS |
| Origin contains HEAD | yes | `origin/arch/eng-0005-execution-transition` | PASS |
| Worktree | clean, nothing staged, nothing untracked | clean | PASS |
| G11-N implementation `358fe47` | present | ancestor | PASS |
| G11-N report `4f4d44f` | present | ancestor (is HEAD) | PASS |
| Fabric (released `inspect_records`) | valid | `status: reported`, no defects | PASS |
| Trust | valid | `valid: true`, `problems: []` | PASS |
| Installed Generation 11 | unchanged | 57 objects, 9-file closure | PASS |
| Root Authority | unmounted | unmounted | PASS |
| CADV count | 2 | 2 | PASS |
| `capability-advertisement.seq` | 2 | 2 | PASS |
| CINST / CROUTE / CSEL | 1 / 1 / 0 | 1 / 1 / 0 | PASS |
| `/etc/kyri/fabric/cadv-000003.json` | absent | **absent** | PASS |

```
Fabric-content  f75dd8e68d74d19065070d08edd8f0781532fca93101eaf176bbdc046185f503
Fabric-metadata d66da53caa7ecc663f26609e41be633a669def4efc4712414930abf953e8ecf3
Trust           cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact        30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence        227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime         80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

### Production inventory

```
CAPDEF-0001   CCON-0001   CPKG-0001   CHOST-0001
CADV-000001 (superseded)  CADV-000002 (head)
CINST-000001              CROUTE-0001

absent: CADV-000003, CINST-000002, CROUTE-0002, CSEL-000001

advertisement.seq 2 | instance.seq 1 | route.seq 1 | selection.seq ABSENT
```

### Clocks at start

```
CADV-000002  valid_until     2026-08-29T09:24:51-05:00   17h 06m   FRESH
CINST-000001 admitted_until  2026-08-29T13:46:27-05:00   21h 27m   VALID
```

**`CADV-000002`'s freshness is not a precondition of this renewal.** G11-N
proved permanently that an expired predecessor may still be lawfully superseded
— freshness gates *consumption*, not *supersession*. Recorded, and depended upon
by nothing here.

---

## 3. The 48-hour validity ruling

> **CADV-000003 uses a reviewer-authorised 48-hour ENG-0005 bootstrap validity
> window. The duration remains ceremony policy only and must not be inferred as
> a platform default.**

Applied exactly as ruled:

```
observed_at = recorded_at = one fresh ceremony instant
valid_until = observed_at + exactly 48 hours
```

**What this ruling is not**, restated because it is easy to lose:

- **not** an ADR-derived default;
- **not** a schema default;
- **not** a runtime default;
- **not** a permanent platform freshness policy;
- **not** authority to apply 48 hours to any future advertisement.

**Nothing was encoded.** No constant, no config value, no schema restriction, no
implementation change. G11-N established that source constrains only *ordering*
— there is no minimum, maximum, or default anywhere in `tools/fabric/` or the
schema — so this duration lives in the ceremony body and the report, and nowhere
else.

**The stated reason, recorded:** operational governance safety. The deliberate
review and approval checkpoints must not create pressure to race an expiring
advertisement. Forty-eight hours remains bounded while giving room for the
remaining first-selection and first-execution ceremony chain.

This supersedes the previous 24-hour ceremony ruling **for `CADV-000003`
only**.

---

## 4. Field-by-field derivation

Every value read from live authority and cross-checked. Nothing trusted from the
brief.

### 4.1 The predecessor is the chain head

```
advertisement_head(CADV-000002)  ->  CADV-000002      <- head, so R4 is satisfiable
advertisement_head(CADV-000001)  ->  CADV-000002
peek_next_id(capability-advertisement)  ->  CADV-000003
```

Renewal rule **R4** requires `advertisement_head(store, supersedes) ==
supersedes`; naming a non-head predecessor would refuse
`renewal-predecessor-not-current`. `CADV-000002` is therefore the only lawful
predecessor today.

### 4.2 The table

| Field | Value | Disposition | Authority, verified |
|---|---|---|---|
| `request_id` | `g11o-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000002` | **new** | ceremony convention `<checkpoint>-<operation>-<subjects>`, as in `g11f-…-supersedes-cadv-000001` |
| `actor` | `CHOST-0001` | copied, verified | `CADV-000002.evidence.actor`; must equal `capability_host_id` — a host advertises only itself |
| `recorded_at` | `2026-08-28T16:19:19-05:00` | **fresh** | one clock read this checkpoint |
| `capability_host_id` | `CHOST-0001` | copied, verified | `CADV-000002.capability_host_id`; R2 requires the same host |
| `capability_package_id` | `CPKG-0001` | copied, verified | `CADV-000002.capability_package_id`; R3 requires the same package |
| `contract_id` | `CCON-0001` | copied, verified | `CPKG-0001.contract_id == CCON-0001` — the package names it |
| `satisfied_contract_versions` | `["1.0.0"]` | copied, verified | `CPKG-0001.satisfied_contract_versions == ["1.0.0"]`, `CCON-0001.contract_version == 1.0.0` |
| `advertised_resource_profile` | `{"architecture": "x86-64"}` | copied, verified | equals `CHOST-0001.verified_resource_profile` exactly — not widened |
| `observed_at` | `2026-08-28T16:19:19-05:00` | **fresh** | `== recorded_at`, per ruling |
| `valid_until` | `2026-08-30T16:19:19-05:00` | **fresh** | `observed_at + 48h`, per ruling |
| `supersedes` | `CADV-000002` | **supersession link** | the current chain head (§4.1) |
| `provenance` | `{class, source, recorded_at: 2026-08-28}` | `class`/`source` copied, date **fresh** | shape unanimous across `cadv-000001.json` and `cadv-000002.json` |

**Agreement checks, all passing:**

```
actor == capability_host_id                        True
package names the contract                         True
versions declared by the package                   True
claim equals the host's verified profile           True
```

### 4.3 Deliberately absent

- **`approving_authority`** — supplying one refuses
  `unexpected-approving-authority`; recording an approver would turn a
  self-report into an approval.
- **`description`, `notes`** — optional, and absent from both `cadv-000001.json`
  and `cadv-000002.json`. Precedent is to omit.
- **overlap fields** — advertisements have no overlap concept at all (G11-N Q4:
  zero references in source and schema).
- **any additional resource claim** — the host has verified exactly one
  dimension; claiming more refuses `resource-claim-not-verified`.

---

## 5. The exact body

```json
{
  "request_id": "g11o-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000002",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-28T16:19:19-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-28T16:19:19-05:00",
  "valid_until": "2026-08-30T16:19:19-05:00",
  "supersedes": "CADV-000002",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

```
BODY_SHA256     66b2c197d700502a9c2c3d5589309686b69aa9ef8249245d92746313b7ecbb26
size            671 bytes
REQUEST_DIGEST  sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
```

Formatting verified: UTF-8, LF only (**0** carriage returns), two-space indent,
**exactly one** trailing newline. A byte-identical copy was retained for the
`cmp` in §10.

---

## 6. Temporal proof

```
observed_at  2026-08-28T16:19:19-05:00
recorded_at  2026-08-28T16:19:19-05:00
valid_until  2026-08-30T16:19:19-05:00

PASS  all instants timezone-aware
PASS  observed_at == recorded_at
PASS  valid_until > observed_at
PASS  observed_at <= recorded_at < valid_until
PASS  valid_until - observed_at == exactly 48 hours
      delta = 2 days, 0:00:00
```

### Absolute expiry

```
America/Chicago  2026-08-30T16:19:19-05:00
UTC              2026-08-30T21:19:19+00:00
```

**No preparation timestamp was reused.** The instant is a single fresh clock
read taken during this checkpoint and frozen into the reviewed bytes; nothing
downstream reads a clock.

---

## 7. Fixture rehearsal and write equivalence

An isolated fixture built **entirely through released governance operations** —
`declare_capability`, `declare_contract`, `declare_package`, `admit_subject`,
`register_advertisement` twice — reproducing the production predecessor shape
`CADV-000002 supersedes CADV-000001`.

```
PASS: the fixture reproduces the production predecessor shape
PASS: CADV-000002 supersedes CADV-000001 and is the chain head
PASS: the fixture predicts CADV-000003
PASS: rehearsal outcome is preflight              [preflight/None]
PASS: rehearsal reason is none
PASS: rehearsal names no record
PASS: no allocation and no write
PASS: the advertisement sequence is unchanged     [2]
PASS: the predecessor record is unchanged
PASS: Trust is unchanged
      rehearsal request digest: sha256:b86457da…282c5d
```

**The write ran in a second, independent fixture**, so the rehearsal fixture was
never mutated to prove it:

```
PASS: the identical body is accepted in a second fixture   [accepted/None]
PASS: the written identity is CADV-000003
PASS: the write carries the same request digest as the rehearsal
PASS: the successor names CADV-000002
PASS: the successor is filed as supersession
PASS: the successor's evidence references the predecessor
PASS: the chain head moves to CADV-000003
PASS: the predecessor acquires no superseded_by backlink
PASS: governed fields agree with the candidate
PASS: the stored window is exactly 48 hours       [2 days, 0:00:00]
PASS: no approving authority was recorded
```

**22 assertions, all passing.** The predecessor is read and never written —
supersession is a forward statement by the successor, and `superseded_by`
remains derived legacy structure that nothing writes.

---

## 8. Live production preflight

Run from an isolated approved **preparation** directory, before anything was
placed under `/etc/kyri/fabric`:

```bash
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000003.json --approved-directory <isolated preparation directory>
```

```json
{
  "destination": "/var/lib/kyri/fabric/capability-advertisements/CADV-000003.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "register-advertisement",
  "outcome": "preflight",
  "predicted_record_id": "CADV-000003",
  "record_kind": "capability-advertisement",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d",
  "request_id": "g11o-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000002",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

**exit 0.** Every required value checked individually:

```
outcome              OK   'preflight'
would_accept         OK   True
predicted_record_id  OK   'CADV-000003'
destination_exists   OK   False
mutated              OK   False
rehearsal_reason     OK   None
request_digest       OK   'sha256:b86457da…282c5d'
```

```
capability-advertisement.seq remains 2
CADV count remains 2
```

### 8.1 One digest across all three

```
fixture rehearsal     sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
fixture write         sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
production preflight  sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
```

The body rehearsed in a fixture, written in a fixture, and evaluated against the
live store are provably **one body** — and the production run consulted the real
`CADV-000002`, `CHOST-0001`, `CPKG-0001` and `CCON-0001`, because it executed
under `admission.rehearsing()` against the production store.

---

## 9. Production no-mutation

| Authority | Before | After | |
|---|---|---|---|
| Fabric — content | `f75dd8e68d74d19065070d08edd8f0781532fca93101eaf176bbdc046185f503` | same | **IDENTICAL** |
| Fabric — metadata | `d66da53caa7ecc663f26609e41be633a669def4efc4712414930abf953e8ecf3` | same | **IDENTICAL** |
| Trust | `cffd362c…fbbc39` | same | **IDENTICAL** |
| Artifact | `30732e2c…6257f` | same | **IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | same | **IDENTICAL** |
| Installed runtime | `80f9dee2…07f5b` | same | **IDENTICAL** |

Per-path structural manifest, before vs after: **no structural change**.

```
CADV = 2   CINST = 1   CROUTE = 1   CSEL = 0
capability-advertisement.seq = 2
/etc/kyri/fabric/cadv-000003.json : ABSENT
Root Authority : unmounted
```

**No privileged operation; every command ran as uid 1000.**

---

## 10. Operator freeze — prepared, NOT performed

### The boundary, re-derived rather than assumed

```
/etc/kyri/fabric                    root:cschott  0750
/etc/kyri/fabric/capdef-0001.json   root:cschott  0640    783 bytes
/etc/kyri/fabric/ccon-0001.json     root:cschott  0640   1474 bytes
/etc/kyri/fabric/cpkg-0001.json     root:cschott  0640   1147 bytes
/etc/kyri/fabric/chost-0001.json    root:cschott  0640   1125 bytes
/etc/kyri/fabric/cadv-000001.json   root:cschott  0640    609 bytes
/etc/kyri/fabric/cadv-000002.json   root:cschott  0640    671 bytes
/etc/kyri/fabric/cinst-000001.json  root:cschott  0640   1211 bytes
/etc/kyri/fabric/croute-0001.json   root:cschott  0640    622 bytes
```

**Unanimous across all eight: `root:cschott`, mode `0640`.** Read from disk, not
recalled.

### Why this checkpoint stopped

```
running as cschott uid=1000
touch /etc/kyri/fabric/.g11o-probe  ->  Permission denied
```

### Validated in a sandbox first

With `DEST` redirected, the block reconstructed the bytes to
`66b2c197…bb26`, **byte-identical** to the retained candidate copy (`cmp`
clean), parsed as JSON, installed at mode `0640`, size **671**, and **refused on
a second run** because the destination existed. `/etc/kyri/fabric` was never
written.

### The block

```bash
set -Eeuo pipefail

DEST=/etc/kyri/fabric/cadv-000003.json
EXPECTED=66b2c197d700502a9c2c3d5589309686b69aa9ef8249245d92746313b7ecbb26

[[ -e "${DEST}" ]] && { printf 'REFUSING: %s already exists\n' "${DEST}" >&2; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11o-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000002",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-28T16:19:19-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-28T16:19:19-05:00",
  "valid_until": "2026-08-30T16:19:19-05:00",
  "supersedes": "CADV-000002",
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
sudo python3 -c 'import json;json.load(open("/etc/kyri/fabric/cadv-000003.json"));print("JSON OK")'
```

### Verification to supply back

```
path      /etc/kyri/fabric/cadv-000003.json
owner     root:cschott
mode      0640
size      671
sha256    66b2c197d700502a9c2c3d5589309686b69aa9ef8249245d92746313b7ecbb26
JSON      parses
CADV count still 2 ; capability-advertisement.seq still 2
```

### Post-freeze preflight — **not run**, because the freeze did not happen

Once frozen, run and require exact agreement with §8:

```bash
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000003.json \
  --approved-directory /etc/kyri/fabric
```

Expect `CADV-000003`, `would_accept: true`, `mutated: false`,
`destination_exists: false`, and request digest `sha256:b86457da…282c5d`. Also
`cmp` the frozen file against the reviewed candidate — **digest equality alone
is not the check**; byte identity is.

**A different request digest means the frozen bytes are not the reviewed bytes —
stop.**

### The write — ⚠ NOT AUTHORISED BY THIS CHECKPOINT

```bash
# NOT AUTHORISED BY THIS CHECKPOINT.
# Requires reviewer approval and separate operator authorisation.
# This spends CADV-000003 permanently in an append-only store.
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000003.json \
  --approved-directory /etc/kyri/fabric
```

---

## 11. Clocks, and what `CADV-000003` does not do

```
observed at              2026-08-28T16:21:05-05:00

CADV-000002  expires     2026-08-29T09:24:51-05:00   17h 03m   FRESH
CINST-000001 expires     2026-08-29T13:46:27-05:00   21h 25m   VALID
CADV-000003  would expire 2026-08-30T16:19:19-05:00   47h 58m  (proposed)
```

### ⚠ `CADV-000003` does **not** update `CINST-000001`

G11-N answered this from source (Q8): `register_advertisement` contains **zero**
references to `capability-instance`. Records are immutable, and `CINST-000001`
is permanently bound to `CADV-000002` — the advertisement that admitted it
(G11-A1).

**Publishing `CADV-000003` will not rescue `CINST-000001` from ELIG-6
staleness.** When `CADV-000002` lapses at `2026-08-29T09:24:51-05:00`,
`CINST-000001` becomes permanently ineligible for selection, and only a **new
admission** against `CADV-000003` restores eligibility —
`automatic_readmission` is forbidden and `recovery: requires-new-decision`.

The renewal chain therefore remains: `CADV-000003` → `CINST-000002` →
`CROUTE-0002` → `CSEL-000001`.

---

## 12. Route renewal and the deferred hardening findings

**Answer B, accepted.** After `CADV-000003` and `CINST-000002 supersedes
CINST-000001`, `CROUTE-0001` cannot represent the renewed chain: a supersession
is not in `LIFECYCLE_CATEGORIES`, so `_binding_root(CINST-000002) ==
CINST-000002` — a **new** binding — and selection reads the named candidate with
no forward walk for instances. **`CROUTE-0002` is required.**

**Reviewer ruling: `ROUTE_HEAD_HARDENING_BEFORE_CROUTE_0002 = NO`.** Production
holds exactly one route, so `CROUTE-0001` is necessarily the current head, and a
correctly prepared `CROUTE-0002 supersedes CROUTE-0001` cannot exercise the
G11-K non-head-predecessor defect.

**Route-head enforcement was not patched here.**

### Deferred hardening deadline

Both G11-K findings carry forward, and the route-head one now has a **deadline**:

| Finding | Status | Mandatory before |
|---|---|---|
| **Route predecessor / head enforcement** — a fork is creatable; selection then refuses the whole traversal as `route-chain-unreadable` | deferred, unpatched | **`CROUTE-0003` (or any later route supersession) OR ENG-0005 closure, whichever comes first** |
| **Withdrawn-binding route admission** — `create_route` reads the named record's frozen `lifecycle_state`; selection compensates with `instance-not-admitted` | deferred, unpatched | no deadline set; still compensated |

---

## 13. Actions NOT performed

- **`CADV-000003` not written.** `capability-advertisement.seq` still 2; CADV
  count still 2.
- **`/etc/kyri/fabric/cadv-000003.json` not frozen** — the privileged step (§10).
- **No `CINST-000002`, no `CROUTE-0002`, no `CSEL-000001`.**
- **Nothing withdrawn or retired.**
- **Route-head enforcement not patched; withdrawn-binding routing not patched.**
- **No source or test change**; no constant, config value or schema restriction
  created for the 48-hour duration (§3).
- **Trust, Artifact and Platform Evidence not mutated.**
- **Runtime not modified; Generation 11 not reinstalled.**
- **Sudoers untouched; Root Authority not mounted.**
- **No package staged, nothing invoked.**
- **ENG-0006 not begun; no TrustGateway cutover.**
- **Neither existing clock raced or renewed.**
- **No privileged operation, no `sudo`.** The only `sudo` in this report is
  inside the §10 block, which was **not run**.
- **No secrets recorded.**

---

## 14. Readiness for the separately authorised `CADV-000003` write

**Conditional YES**, in this order:

1. **Reviewer approves** the body in §5, its digests, and the 48-hour
   application.
2. **Operator freezes** with the §10 block → `root:cschott 0640`, 671 bytes,
   `66b2c197…bb26`, and supplies the verification back.
3. **Post-freeze preflight** from `/etc/kyri/fabric` — must return
   `would_accept: true`, `CADV-000003`, and digest `sha256:b86457da…282c5d`;
   plus `cmp` proving byte identity, not merely digest equality.
4. **Then** the write, under separate authorisation.

**Not ready today** solely because step 2 has not happened. Nothing else stands
in the way — the preflight already passes against live production.

### Timing note for the sequencing

The 48-hour window expires `2026-08-30T16:19:19-05:00`. That is comfortably
beyond `CADV-000002`'s lapse tomorrow morning, which is the point of the ruling:
the renewal can be written without racing, and the subsequent `CINST-000002`
admission then has room. Note that `CINST-000002` must be admitted **while
`CADV-000003` is fresh** — the advertisement clock gates admission and selection,
not route creation.

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo` at any point.**

```bash
# Mandatory preflight
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
git branch -r --contains 4f4d44f ; git merge-base --is-ancestor <358fe47|4f4d44f> HEAD
ls -1 /etc/kyri/fabric/                                  # cadv-000003.json ABSENT
python3 -c "<inspect_records, read-only>"
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )

# Derivation, from live authority
python3 -c "<advertisement_head, peek_next_id>"
python3 -c "<CADV-000002 / CHOST-0001 / CPKG-0001 / CCON-0001 field agreement>"
python3 -c "<provenance shape across cadv-000001.json and cadv-000002.json>"

# Body and temporal proof
python3 - <<'PY' ... PY        # one clock read; five temporal assertions
sha256sum <candidate>          # 66b2c197…bb26 ; size 671 ; JSON parses ; LF only

# Fixture rehearsal + independent second-fixture write
python3 <rehearse-g11o.py> <candidate>                   # 22 assertions

# Live production preflight
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000003.json --approved-directory <isolated dir>
<content AND metadata digests, before and after>

# Freeze precedent and block validation
stat -c '%n %U:%G %a %s' /etc/kyri/fabric /etc/kyri/fabric/*.json
touch /etc/kyri/fabric/.g11o-probe                       # Permission denied
<heredoc reconstruction in a sandbox; sha256sum; cmp; json.load; re-run refusal>
```

## Appendix B — the candidate, stated once

```
CADV-000003   predicted, NOT written, NOT frozen

  supersedes      CADV-000002        <- verified the current chain head
  host            CHOST-0001         <- R2: same host
  package         CPKG-0001          <- R3: same package
  contract        CCON-0001          <- the package names it
  versions        ["1.0.0"]          <- declared by the package
  claim           architecture x86-64 <- exactly the host's verified profile

  observed_at     2026-08-28T16:19:19-05:00
  recorded_at     2026-08-28T16:19:19-05:00   == observed_at
  valid_until     2026-08-30T16:19:19-05:00   = +48h EXACTLY
                  UTC 2026-08-30T21:19:19+00:00

  absent          approving_authority, description, notes, overlap,
                  any extra resource dimension

  BODY_SHA256     66b2c197d700502a9c2c3d5589309686b69aa9ef8249245d92746313b7ecbb26
  size            671 bytes
  REQUEST_DIGEST  sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
                  ^ ONE digest across fixture rehearsal, fixture write,
                    and live production preflight

THE 48 HOURS ARE CEREMONY POLICY, NOT A PLATFORM DEFAULT.
Nothing was encoded -- no constant, no config, no schema, no runtime change.

AND CADV-000003 DOES NOT RESCUE CINST-000001.
The instance names CADV-000002 permanently; a new admission is required.
```
