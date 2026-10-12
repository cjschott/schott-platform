# ENG-0005 G11-L — CROUTE-0001 Ceremony Preparation, Live Preflight, and Frozen Operator Input

**Date:** 2026-08-28
**Checkpoint:** G11-L
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

> ## 🔐 STOPPED AT THE PRIVILEGED BOUNDARY
>
> Everything this checkpoint could do without privilege is **done and passing**.
> The candidate is derived, rehearsed, and preflighted against live production
> with `would_accept: true`.
>
> **The freeze itself was not performed.** `/etc/kyri/fabric` is
> `root:cschott 0750` and this session runs as uid 1000; a write probe was
> refused. The exact copy/paste operator block is in §10, validated
> byte-for-byte in a sandbox.
>
> **`RESULT=OPERATOR_ACTION_REQUIRED`.** The production `create-route` write was
> **not** performed and is not authorised by this checkpoint.

---

## 1. Objective and outcome

**Objective.** Prepare the first governed production capability route,
`CROUTE-0001`: derive the body from committed architecture and live governed
records, rehearse it, preflight it against production read-only, and freeze the
operator input. Do not write.

**Outcome: OPERATOR_ACTION_REQUIRED** — every unprivileged step complete and
passing; the freeze awaits the operator.

- The body is **derived field-by-field from governed records**, not assumed
  (§4). Every value is traceable to a record on disk or a released vocabulary.
- **18 fixture assertions pass** against a world built entirely through released
  governance operations (§6).
- **The live production preflight returns `would_accept: true`** with
  `predicted_record_id: CROUTE-0001` and `rehearsal_reason: null` (§7).
- **The fixture and production request digests are identical** —
  `sha256:09c6b35b…9aba34` — so the rehearsed body and the preflighted body are
  provably one body (§8).
- **Production is byte-identical**, content *and* metadata, across every
  authority (§9).
- **No source change was made or needed.** `IMPLEMENTATION_COMMIT=NONE`.

Neither G11-K deferred finding was exercised: this route has no predecessor and
its candidate is an admitted binding root (§12).

---

## 2. Starting authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | same | PASS |
| HEAD | `cec61739409376432f879e64ff35a45171af5027` | same | PASS |
| Origin contains HEAD | yes | `origin/arch/eng-0005-execution-transition` | PASS |
| Worktree | clean, nothing staged, nothing untracked | clean | PASS |
| G11-K implementation `3ca8f1e` ancestor | yes | yes | PASS |
| G11-K report `cec6173` ancestor | yes | yes (is HEAD) | PASS |

### Production, before

```
capability-definitions    1   CAPDEF-0001
capability-contracts      1   CCON-0001
capability-packages       1   CPKG-0001
capability-hosts          1   CHOST-0001
capability-advertisements 2   CADV-000001, CADV-000002
capability-instances      1   CINST-000001
capability-routes         0
capability-selections     0

capability-route.seq      ABSENT
capability-selection.seq  ABSENT
```

| Check | Result |
|---|---|
| Fabric structurally valid (released `inspect_records`, read-only) | **`status: reported`, no defects** |
| Trust store | **`valid: true`, `problems: []`** |
| Installed Generation 11 | **57 objects, 9-file Fabric closure** |
| `current-generation` | `CGEN-000000000001`, digest `fc9a3ec3…0163` |
| Root Authority | **unmounted** |

```
Fabric-content  4d95072bf3cc3553c61654a382ae85aca52b851f35c2fd83b0169bf069a02ccf
Fabric-metadata 6ac5a98a1b7cf5fde405a2f942730e05fbeb3ab3e9c25459fd0f3f6000dad82a
Trust           cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact        30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence        227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime         80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

The metadata digest covers per-path size, mtime, mode and owner — a
content-only digest would not notice a sequence file rewritten to the same value
or a lock left behind.

---

## 3. Route semantics, reconstructed from source

Restated compactly from G11-K §3, re-verified against the same source:

| Property | Value |
|---|---|
| Operation | `create_route(store, *, ...)` — **no `trust_store` parameter** |
| CLI | `create-route`; `WRITE_OPERATIONS[...] = ("create_route", False)`; not in `NEEDS_EVIDENCE` |
| Trust | **not consumed** — spent once at admission |
| Advertisement | **never referenced** — zero occurrences in `create_route` |
| Expiry | **none** — no `valid_until`, no validity window |
| Currentness | supersession chain + strictly increasing `route_version` |
| Identity | `^CROUTE-[0-9]{4}$`, width 4 → **`CROUTE-0001`** |
| Candidate rules | resolves; matches route capability **and** contract; is a binding root; own record says `admitted` |
| Selection | no route → no candidate; two current routes → `route-ambiguous-for-request-class` |

**Because `create_route` never reads an advertisement, this ceremony is
independent of `CADV-000002`'s clock** — the reviewer ruling not to race it is
satisfied structurally, not by scheduling.

---

## 4. The exact `CROUTE-0001` body, field by field

Every field traced to its authority. Nothing guessed.

| Field | Value | Required | Authority | Why present |
|---|---|---|---|---|
| `request_id` | `g11l-create-route-capdef-0001-ccon-0001-cinst-000001` | required | ceremony convention: `<checkpoint>-<operation>-<subjects>`, as in `s4a-admit-subject-fabric-node-host-0001`, `g11i-admit-instance-cpkg-0001-chost-0001-cadv-000002` | governed request identity; names the operation and its subjects, never the unminted result |
| `actor` | `primary-platform-operator` | required | **`CHOST-0001.evidence.actor`** and **`CINST-000001.evidence.actor`** | `_human_authority` requires it; Ruling 4 — the established spelling, not a new one |
| `approving_authority` | `primary-platform-operator` | required | same two records | `_human_authority`; a route is a human decision |
| `recorded_at` | `2026-08-28T15:07:19-05:00` | required | one clock read at preparation | `_human_preflight` requires an aware instant; `create_route` imposes no window on it |
| `capability_id` | `CAPDEF-0001` | required | `CAPDEF-0001.capability_id`; agrees with `CCON-0001`, `CPKG-0001`, `CINST-000001` | the request class's capability |
| `contract_id` | `CCON-0001` | required | `CCON-0001.contract_id`; `CCON-0001.capability_id == CAPDEF-0001` | the request class's contract; `create_route` requires the contract be the capability's |
| `accepted_contract_versions` | `["1.0.0"]` | required | **derived, not hard-coded**: `CCON-0001.contract_version = 1.0.0`, `CPKG-0001.satisfied_contract_versions = [1.0.0]`, `CINST-000001.satisfied_contract_versions = [1.0.0]` — all three agree | must be non-empty; selection matches the set exactly |
| `locality` | `local-only` | required | `LOCALITIES = ('local-only','operator-controlled-only','any-trusted')`; **Ruling 2** | §5 |
| `candidate_instances` | `["CINST-000001"]` | required | `CINST-000001`: `lifecycle_state: admitted`, `supersedes` absent (its own binding root), `capability_id`/`contract_id` match | the only admitted binding in the fabric |
| `data_classification` | `internal` | required | **derived**: `CHOST-0001.data_classification = internal` and `CINST-000001.effective_scope.permitted_data_classifications = [internal]`; `WORKLOAD_DATA_CLASSIFICATIONS = ('internal',)` | the request class's classification |
| `route_version` | `1` | required | `int >= 1`; this is the first route in its chain | Ruling 3 |
| `provenance` | `{class, source, recorded_at}` | required | precedent: **all seven** frozen operator inputs carry this exact shape; `source` matches `cadv-000001/2`, `ccon-0001`, `chost-0001`, `cinst-000001`, `cpkg-0001` | `_mapping`; declared provenance |

**Deliberately absent**, per Ruling 3:

- `supersedes` — this is the first route; no predecessor exists.
- `overlap_starts_at` / `overlap_ends_at` — an overlap window is permitted only
  alongside a supersession, and refuses as
  `overlap-window-without-supersession` otherwise.
- `description`, `notes` — optional in the schema. Precedent is split (present
  in `capdef`, `ccon`, `cpkg`, `chost`; absent from `cadv-000001`,
  `cadv-000002`, `cinst-000001` — the three most recent). Nothing requires one,
  so none was invented.

```json
{
  "request_id": "g11l-create-route-capdef-0001-ccon-0001-cinst-000001",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T15:07:19-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000001"
  ],
  "data_classification": "internal",
  "route_version": 1,
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

```
BODY_SHA256     fb3f713e37deb70c6236b807a45e58ccc5fc756151075c775f8ceebe8785ece0
size            622 bytes
REQUEST_DIGEST  sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
```

**Frozen together and inseparable:** the bytes, their SHA-256, and the request
digest. Changing any field regenerates all three.

---

## 5. Locality — `local-only`, and why

Ruling 2 applied. `local-only` is the **narrowest** released locality:

```python
if locality == "any-trusted":
    return True
if locality == "operator-controlled-only":
    return host.get("location_class") != THIRD_PARTY_HOSTED
if local_node_identity is None:
    return False
return host.get("node_identity_reference") == local_node_identity
```

> *"`local-only` is exact identity equality against the node performing the
> selection. Nothing is inferred from a location class, a hostname, an endpoint,
> or a resemblance between strings, and where no usable identity was supplied
> the answer is no."*

So the first governed route obliges the eventual selection to **prove exact
local node identity** — `HOST-0001` — rather than accepting anything trusted.
It was not widened for convenience.

**Route locality is not `CHOST-0001.location_class`.** The host declares
`location_class: on-premises`, which belongs to a different vocabulary and is
consumed only by `operator-controlled-only`. Confusing the two would put a token
outside `LOCALITIES` into the body and refuse as `unknown-locality`.

---

## 6. Fixture rehearsal

The production semantic shape reproduced in an isolated temporary root **through
released governance operations only** — `declare_capability`,
`declare_contract`, `declare_package`, `admit_subject`,
`register_advertisement`, `admit_instance` — not by copying production. The
fixture independently allocates the same identities, which is itself a check
that the production lineage was built the same way.

```
PASS: the fixture reproduces the production identities
      [CAPDEF-0001 CCON-0001 CPKG-0001 CHOST-0001 CINST-000001]
PASS: the fixture binding is admitted and is its own binding root
PASS: the fixture predicts CROUTE-0001
PASS: rehearsal outcome is preflight              [preflight/None]
PASS: rehearsal reason is None
PASS: rehearsal names no record
PASS: no route was written
PASS: capability-route.seq remains absent
PASS: the fixture Fabric is otherwise unchanged
PASS: the fixture Trust store is unchanged
      fixture request digest: sha256:09c6b35b…9aba34
```

A **second, separate** fixture proves the prediction is what allocation hands
out — so the first fixture stays unmutated:

```
PASS: the same body is accepted when written to a second fixture   [accepted/None]
PASS: the written identity is CROUTE-0001
PASS: the write carries the same request digest as the rehearsal
PASS: the stored route binds the governed request class
PASS: the stored route names CINST-000001 as its only candidate
PASS: the stored route is version 1, supersedes nothing, declares no overlap
PASS: the stored route is filed as route-change
```

**18 assertions, all passing.** No Trust mutation, no execution, no staging.

---

## 7. Live production read-only preflight

```bash
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0001.json --approved-directory <isolated preparation directory>
```

```json
{
  "destination": "/var/lib/kyri/fabric/capability-routes/CROUTE-0001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "create-route",
  "outcome": "preflight",
  "predicted_record_id": "CROUTE-0001",
  "record_kind": "capability-route",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34",
  "request_id": "g11l-create-route-capdef-0001-ccon-0001-cinst-000001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

**exit 0.** Every required condition met: `outcome preflight`,
`would_accept true`, `predicted_record_id CROUTE-0001`, `rehearsal_reason null`,
`destination_exists false`, `mutated false`.

Nothing was published to `/etc/kyri/fabric` to obtain it — `--approved-directory`
is operator-named and containment is enforced against whatever directory is
named, so an isolated preparation directory applies the same rule to a tighter
root (the pattern established in G11-F §10).

---

## 8. Rehearsal and production agree

```
fixture rehearsal   sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
fixture write       sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
production preflight sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
```

**One digest across all three.** The body rehearsed in a fixture, the body
written in a fixture, and the body evaluated against the live stores are the
same body — and the production run consulted the real `CAPDEF-0001`,
`CCON-0001`, `CINST-000001` and `CHOST-0001`, since it executed under
`admission.rehearsing()` against the production store.

Predicted identity is `CROUTE-0001` in both. **No governed semantic differs.**

---

## 9. Production no-mutation, forensic

Taken around the live preflight, content **and** metadata:

| Authority | Result |
|---|---|
| Fabric — content | **IDENTICAL** |
| Fabric — metadata (size, mtime, mode, owner, per path) | **IDENTICAL** |
| Trust | **IDENTICAL** |
| Artifact | **IDENTICAL** |
| Platform Evidence | **IDENTICAL** |
| Installed runtime | **IDENTICAL** |

```
CROUTE count          : 0
CSEL count            : 0
capability-route.seq  : ABSENT
```

No allocation, no route write, no sequence created. **No privileged operation
was performed at any point; every command ran as uid 1000.**

---

## 10. Operator freeze — prepared, NOT performed

### The approved-input boundary, derived

```
/etc/kyri/fabric                    root:cschott  0750
/etc/kyri/fabric/capdef-0001.json   root:cschott  0640    783 bytes
/etc/kyri/fabric/ccon-0001.json     root:cschott  0640   1474 bytes
/etc/kyri/fabric/cpkg-0001.json     root:cschott  0640   1147 bytes
/etc/kyri/fabric/chost-0001.json    root:cschott  0640   1125 bytes
/etc/kyri/fabric/cadv-000001.json   root:cschott  0640    609 bytes
/etc/kyri/fabric/cadv-000002.json   root:cschott  0640    671 bytes
/etc/kyri/fabric/cinst-000001.json  root:cschott  0640   1211 bytes
```

**Unanimous precedent: `root:cschott`, mode `0640`.** Not assumed from memory —
read from all seven existing inputs. This is an operator-approved frozen
decision input, root-owned and not writable by the repository identity, which is
what makes it a different authority class from repository source.

### Why this checkpoint stopped here

```
running as: cschott uid=1000
touch /etc/kyri/fabric/.g11l-probe  ->  Permission denied
```

The freeze requires root. Per the brief, the block below is provided and the
privileged action is **not** taken.

### Validated before being written here

With `DEST` redirected to a sandbox path, the block reconstructed the bytes to
`fb3f713e…5ece0`, **byte-identical** to the preflighted candidate (`cmp` clean),
parsed as JSON, installed at mode `0640`, size 622 bytes, and **refused on a
second run** because the destination existed. `/etc/kyri/fabric` was never
written.

### The operator block

```bash
set -Eeuo pipefail

DEST=/etc/kyri/fabric/croute-0001.json
EXPECTED=fb3f713e37deb70c6236b807a45e58ccc5fc756151075c775f8ceebe8785ece0

[[ -e "${DEST}" ]] && { printf 'REFUSING: %s already exists\n' "${DEST}" >&2; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11l-create-route-capdef-0001-ccon-0001-cinst-000001",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T15:07:19-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000001"
  ],
  "data_classification": "internal",
  "route_version": 1,
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
sudo python3 -c 'import json;json.load(open("/etc/kyri/fabric/croute-0001.json"));print("JSON OK")'
```

It sets strict shell options, refuses an existing destination, reconstructs the
reviewed bytes inline, verifies the digest **before** installing, installs
`root:cschott 0640`, removes the temporary material, and prints the destination
digest, metadata and JSON validity. **It does not run `create-route`.**

### Verification to supply back

```
path      /etc/kyri/fabric/croute-0001.json
owner     root:cschott
mode      0640
size      622
sha256    fb3f713e37deb70c6236b807a45e58ccc5fc756151075c775f8ceebe8785ece0
JSON      parses
no alternate croute input exists in /etc/kyri/fabric
CROUTE count still 0 ; capability-route.seq still ABSENT
```

### After the freeze — re-preflight from the approved boundary

```bash
cd /opt/schott-platform
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0001.json \
  --approved-directory /etc/kyri/fabric
```

Expect `would_accept: true`, `predicted_record_id: CROUTE-0001`, and request
digest `sha256:09c6b35b…9aba34`. **A different request digest means the frozen
bytes are not the reviewed bytes — stop.**

### The write — ⚠ NOT AUTHORISED BY THIS CHECKPOINT

```bash
# NOT AUTHORISED BY THIS CHECKPOINT.
# Requires reviewer approval and separate operator authorisation.
# This spends CROUTE-0001 permanently in an append-only store.
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0001.json \
  --approved-directory /etc/kyri/fabric
```

---

## 11. Observed clock state

```
observed at                    2026-08-28T15:09:08-05:00

CADV-000002  valid_until       2026-08-29T09:24:51-05:00   18h 15m   FRESH
CINST-000001 admitted_until    2026-08-29T13:46:27-05:00   22h 37m   VALID
```

**Recorded, and depended upon by nothing.** `create_route` never resolves an
advertisement (§3), so route preparation, rehearsal, preflight and freeze are
all independent of `CADV-000002`'s freshness. The reviewer ruling not to race it
is satisfied by the operation's structure, not by finishing quickly.

**Neither clock was renewed.** No `CADV-000003`, no `CINST-000002`.

The advertisement clock still gates **`CSEL-000001`**, via ELIG-6 — see §14.

---

## 12. G11-K deferred hardening findings

Both are recorded as deferred governed-behaviour rulings, **not repaired here**,
per Ruling 5.

1. **`create_route` may accept a binding root whose lifecycle chain has been
   withdrawn.** It reads the named record's `lifecycle_state`, and a binding
   root's state is frozen at `admitted` forever. Selection compensates,
   excluding the candidate as `instance-not-admitted`.
2. **`create_route` does not require a superseded route to be the chain head**,
   so a fork is creatable; `selection._chain_heads` then refuses the whole
   traversal as `route-chain-unreadable`.

**Neither is exercised by `CROUTE-0001`:**

- it declares **no `supersedes`**, so the head-ness path never runs;
- its candidate `CINST-000001` is an **admitted binding root** whose lifecycle
  chain has exactly one record — verified this checkpoint: `lifecycle_state:
  admitted`, `supersedes` absent, and one record in
  `capability-instances/`.

Nothing about this ceremony unexpectedly exercised either defect, so no STOP was
triggered. Both remain due their own RED-first checkpoints after first governed
selection, unless they become directly blocking earlier.

---

## 13. Actions NOT performed

- **`CROUTE-0001` not written.** `capability-route.seq` absent; CROUTE count 0.
- **`/etc/kyri/fabric/croute-0001.json` not frozen** — the privileged step, §10.
- **No other CROUTE, no CSEL, no `CADV-000003`, no `CINST-000002`.**
- **`CINST-000001` not withdrawn or retired.**
- **Trust, Artifact and Platform Evidence not mutated.**
- **Generation 11 not reinstalled**; installed runtime byte-identical.
- **No sudoers change, Root Authority not mounted.**
- **No package staged, no capability invoked, no Podman use, no Health work.**
- **ENG-0006 not begun; no TrustGateway cutover.**
- **No source or test change** — the G11-K findings were recorded, not patched.
- **No privileged operation, no `sudo`.** The only `sudo` in this report is
  inside the §10 block, which was **not run**.
- **No secrets recorded.**

---

## 14. Blockers, deviations, and readiness

**No blockers. No deviations from the rulings.**

| Ruling | Applied |
|---|---|
| R1 — `CROUTE-0001`, four digits, `croute-0001.json` | ✓ predicted and filename both four-digit |
| R2 — `locality = "local-only"`, not widened, not `location_class` | ✓ §5 |
| R3 — request class derived, `route_version 1`, no supersedes/overlap/description | ✓ §4 |
| R4 — established operator authority | ✓ `primary-platform-operator`, from `CHOST-0001` and `CINST-000001` evidence |
| R5 — G11-K findings not repaired | ✓ §12 |

**Readiness for the separate `CROUTE-0001` production write: conditional YES**,
in this order:

1. **Reviewer approves** the body in §4 and its two digests.
2. **Operator freezes** with the §10 block → `root:cschott 0640`, 622 bytes,
   `fb3f713e…5ece0`, and supplies the verification block back.
3. **Re-preflight from `/etc/kyri/fabric`** — must return `would_accept: true`
   and digest `sha256:09c6b35b…9aba34`.
4. **Then, and only then**, the write under separate authorisation.

The write is **not ready today** because step 2 has not happened. Nothing else
stands in the way.

---

## 15. Recommended next checkpoint

**G11-M — `CROUTE-0001` freeze verification and production write**, once the
operator supplies the §10 result.

After that, the remaining Fabric sequence:

- **`CSEL-000001`**, rehearsed through the G11-C selection preflight before the
  identity is spent. **This one is clock-bound.** `CADV-000002` lapses at
  `2026-08-29T09:24:51-05:00`, after which ELIG-6 finds `CINST-000001`'s
  advertisement stale and the binding is permanently ineligible —
  `automatic_readmission` is forbidden and `recovery: requires-new-decision`. On
  current timing the likely path is `CADV-000003 supersedes CADV-000002`, then
  `CINST-000002` admitted against it, then a route naming that binding, then the
  selection. G11-J §18 set this out and it still holds.
- The two deferred hardening checkpoints from §12.

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo` at any point.**

```bash
# Mandatory preflight
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
git branch -r --contains cec6173 ; git merge-base --is-ancestor <3ca8f1e|cec6173> HEAD
python3 -c "<inspect_records on the production store, read-only>"
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )
( cd /var/lib/kyri/fabric && find . -print0 | sort -z
  | xargs -0 -I{} stat -c '%n %s %Y %a %U:%G' {} | sha256sum )

# Body derivation, from governed records
grep -E '...' /var/lib/kyri/fabric/{capability-contracts/CCON-0001,\
  capability-definitions/CAPDEF-0001,capability-packages/CPKG-0001,\
  capability-hosts/CHOST-0001,capability-instances/CINST-000001}.yaml
python3 -c "<provenance shape across all seven frozen operator inputs>"
sha256sum <candidate>                                  # fb3f713e…5ece0

# Fixture rehearsal, world built through released operations
python3 <rehearse-g11l.py> <candidate>                 # 18 assertions

# Live production read-only preflight
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0001.json --approved-directory <isolated dir>
<content AND metadata digests, before and after>

# Freeze precedent and block validation
stat -c '%n %U:%G %a %s' /etc/kyri/fabric /etc/kyri/fabric/*.json
touch /etc/kyri/fabric/.g11l-probe                     # Permission denied
<heredoc reconstruction in a sandbox; sha256sum; cmp; json.load; re-run refusal>
```

## Appendix B — the candidate, stated once

```
CROUTE-0001   predicted, NOT written

  request class   CAPDEF-0001 / CCON-0001 @ 1.0.0 / internal
  locality        local-only        <- narrowest; selection must prove HOST-0001
  candidate       CINST-000001      <- admitted binding root, sole candidate
  route_version   1
  supersedes      absent            <- first route; head-ness path never runs
  overlap         absent            <- permitted only alongside a supersession

  decided by      primary-platform-operator, approving as operator

  BODY_SHA256     fb3f713e37deb70c6236b807a45e58ccc5fc756151075c775f8ceebe8785ece0
  size            622 bytes
  REQUEST_DIGEST  sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
                  ^ identical across fixture rehearsal, fixture write,
                    and live production preflight

  NOT written. NOT frozen -- /etc/kyri/fabric is root-owned and the freeze
  is the operator's act. No Trust consumed. No advertisement read, so
  CADV-000002's clock does not gate this ceremony.
```
