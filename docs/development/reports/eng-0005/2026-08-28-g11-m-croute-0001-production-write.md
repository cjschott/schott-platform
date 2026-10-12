# ENG-0005 G11-M — CROUTE-0001 Production Write and Independent Verification

**Date:** 2026-08-28
**Checkpoint:** G11-M
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Perform the separately authorised production write of
`CROUTE-0001` from the frozen, reviewed operator input; verify the resulting
immutable route independently; record the ceremony.

**Outcome: ACCEPTED.**

**The first governed capability route in the fabric exists.** `CROUTE-0001`
binds the `CAPDEF-0001` / `CCON-0001` @ `1.0.0` / `internal` request class at
`local-only` locality to the single admitted binding `CINST-000001`.

```
outcome         accepted
reason          null
record_id       CROUTE-0001
record_kind     capability-route
request_digest  sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
```

Every required post-write check passes (§6–§9). The strongest result is the
**exact mutation accounting** (§9): the ceremony added **two pathnames and
nothing else** — the record and its sequence — with **no existing file modified
and none removed**.

- Frozen input verified byte-for-byte against the G11-L candidate (§3).
- Final approved-boundary preflight matched all seven required values (§4).
- Persisted record verified field by field — **15 of 15** (§6).
- `capability-route.seq` contains exactly `1`, corroborated by digest (§7).
- Fabric `status: reported`, no defects; Trust `valid: true`, `problems: []` (§8).
- **Trust, Artifact, Platform Evidence and the installed runtime are
  byte-identical** (§9).
- **No source change.** `IMPLEMENTATION_COMMIT=NONE`.

Neither G11-K deferred finding was exercised (§11).

---

## 2. Starting authority and state

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | same | PASS |
| HEAD | `0237e5ea2a7ae8986cc105d71dbac621c181028c` | same | PASS |
| Worktree | clean, nothing staged, nothing untracked | clean | PASS |

**Production, before the write:**

```
capability-definitions    1        capability-instances      1
capability-contracts      1        capability-routes         0
capability-packages       1        capability-selections     0
capability-hosts          1
capability-advertisements 2

capability-route.seq      ABSENT
Trust                     valid: true, problems: []
Installed Generation 11   57 objects, 9-file Fabric closure
current-generation        CGEN-000000000001, digest fc9a3ec3…0163
Root Authority            unmounted
```

Per-path baseline captured before the write: **23 structural entries, 14 files**
— the basis for §9's accounting.

---

## 3. Frozen input verification

```
path      /etc/kyri/fabric/croute-0001.json
owner     root:cschott
mode      0640
size      622
sha256    fb3f713e37deb70c6236b807a45e58ccc5fc756151075c775f8ceebe8785ece0
JSON      parses
```

**Every value matches the ceremony authority exactly.** Additionally:

- **`cmp` against the G11-L preflighted candidate: BYTE-IDENTICAL.** The bytes
  the operator froze are the bytes that were reviewed and preflighted — not a
  re-serialisation that happens to carry the same digest.
- **Exactly one `croute-*` operator input exists.** No alternate, no draft.

---

## 4. Final approved-boundary preflight

Run from `/etc/kyri/fabric` — the approved input boundary, not a preparation
directory — immediately before the write:

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

Checked field by field against the required values:

```
would_accept          OK   True
predicted_record_id   OK   'CROUTE-0001'
destination_exists    OK   False
mutated               OK   False
outcome               OK   'preflight'
rehearsal_reason      OK   None
request_digest        OK   'sha256:09c6b35b…9aba34'

ALL FINAL CHECKS PASS -- write authorised
```

---

## 5. The production write

Executed exactly as authorised:

```bash
cd /opt/schott-platform

python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 \
  --expected-gid 1000 \
  --input-file croute-0001.json \
  --approved-directory /etc/kyri/fabric
```

**Raw outcome, verbatim:**

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CROUTE-0001",
  "record_kind": "capability-route",
  "request_digest": "sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34",
  "request_id": "g11l-create-route-capdef-0001-ccon-0001-cinst-000001"
}
```

**exit 0.** Identity and digest are the exact authorised combination. Run once;
no retry, no modified input, no repair.

---

## 6. The persisted record

`/var/lib/kyri/fabric/capability-routes/CROUTE-0001.yaml` — `cschott:cschott`,
mode `0600`, 821 bytes, written `2026-08-28 15:25`:

```yaml
accepted_contract_versions:
- 1.0.0
candidate_instances:
- CINST-000001
capability_id: CAPDEF-0001
contract_id: CCON-0001
data_classification: internal
evidence:
  actor: primary-platform-operator
  approving_authority: primary-platform-operator
  causal_references:
  - CAPDEF-0001
  - CCON-0001
  - CINST-000001
  reason_category: route-change
  recorded_at: '2026-08-28T15:07:19-05:00'
  request_digest: sha256:09c6b35b535a7d0424dfc8455deff9937a00c88d52cb8dee4998aaa7e59aba34
  request_id: g11l-create-route-capdef-0001-ccon-0001-cinst-000001
  trust_evidence_references: []
kind: capability-route
locality: local-only
provenance:
  class: declared
  recorded_at: '2026-08-28'
  source: docs/decisions/ADR-0012-distributed-capability-fabric.md
route_id: CROUTE-0001
route_version: 1
schema_version: schott-platform/v1
```

```
CROUTE_SHA256  6bf6aa0f06ff13e9787f7313d17f12f11d61de07b3cf4b9b8e26a7f191c48707
```

### Field-by-field verification — 15 of 15

```
PASS: route_id == CROUTE-0001
PASS: capability_id == CAPDEF-0001
PASS: contract_id == CCON-0001
PASS: accepted_contract_versions == [1.0.0]
PASS: candidate_instances == [CINST-000001]
PASS: locality == local-only
PASS: data_classification == internal
PASS: route_version == 1
PASS: no supersedes
PASS: no superseded_by
PASS: no overlap_window
PASS: evidence request_digest == reviewed
PASS: request_id == g11l-create-route-capdef-0001-ccon-0001-cinst-000001
PASS: reason_category == route-change
PASS: trust_evidence_references empty (routes consume no Trust)
```

Two of these are worth naming. **`trust_evidence_references` is empty** — not an
omission but the architecture: `create_route` takes no trust store, because
Trust was consumed once at admission and the route routes to a binding that
already carries it. And **`causal_references` names the capability, the contract
and the candidate binding, but no advertisement** — `create_route` never
resolves one, which is why this ceremony was independent of the `CADV-000002`
clock.

---

## 7. Sequence

```
/var/lib/kyri/fabric/sequences/capability-route.seq
raw='1\n'   stripped='1'   equals 1: True
sha256      4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865
```

Corroborated independently: `printf '1\n' | sha256sum` produces the identical
digest. The sequence went from **absent** to exactly `1`.

---

## 8. Inventory and validation

| Kind | Count | Required | |
|---|---|---|---|
| `capability-definitions` | 1 | 1 | OK |
| `capability-contracts` | 1 | 1 | OK |
| `capability-packages` | 1 | 1 | OK |
| `capability-hosts` | 1 | 1 | OK |
| `capability-advertisements` | 2 | 2 | OK |
| `capability-instances` | 1 | 1 | OK |
| **`capability-routes`** | **1** | **1** | **OK** |
| `capability-selections` | 0 | 0 | OK |

**Fabric**, through the released read-only inspection surface:

```
status: reported     defects: none
```

**Trust**:

```
valid: true     problems: []
```

Trust was neither read for authorisation nor written by this operation, and it
validates clean afterwards.

---

## 9. Exact mutation accounting

The per-path manifest taken before the write, compared against the same
manifest after. **Every changed pathname, accounted for:**

### Structural entries — two additions, zero removals, zero modifications

```
> f 600 1000:1000   2  ./sequences/capability-route.seq
> f 600 1000:1000 821  ./capability-routes/CROUTE-0001.yaml
```

### File contents — the same two, and nothing else

```
> 6bf6aa0f06ff13e9787f7313d17f12f11d61de07b3cf4b9b8e26a7f191c48707  capability-routes/CROUTE-0001.yaml
> 4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865  sequences/capability-route.seq
```

Both lines are `>` — **additions only**. No `<` line appears, so nothing was
removed and no pre-existing file's content changed.

| Expected mutation | Observed |
|---|---|
| creation of `CROUTE-0001.yaml` | **yes** — 821 bytes, `0600`, `cschott:cschott` |
| `capability-route.seq` absent → `1` | **yes** — 2 bytes, `0600` |
| request-identity metadata the write contract necessarily creates | **none** |

**On the third row:** `request_identity.lock` existed before the ceremony
(created 2026-08-21) and does not appear in either diff — it is a lock, and the
write neither created nor altered it. No per-request identity file was created,
because request identity is carried *in the record's own evidence*
(`request_id` and `request_digest`, §6) rather than in a side table. So the
released write contract created no request-identity metadata here, and the
accounting is complete at two pathnames.

**No unexpected mutation. Nothing to report as a STOP.**

### Authorities outside the Fabric

```
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39   IDENTICAL
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f   IDENTICAL
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b   IDENTICAL
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b   IDENTICAL
```

```
installed runtime : 57 objects
Root Authority    : unmounted
```

`diff` of the before and after captures: **all identical**.

---

## 10. Observed clock state

```
observed at                    2026-08-28T15:26:44-05:00

CADV-000002  valid_until       2026-08-29T09:24:51-05:00   17h 58m   FRESH
CINST-000001 admitted_until    2026-08-29T13:46:27-05:00   22h 19m   VALID
```

**Recorded, and not treated as invalidating `CROUTE-0001`.** Per the timing
ruling: route creation does not consume advertisement freshness, and
`create_route` never resolves an advertisement — confirmed in the persisted
record, whose `causal_references` name no `CADV` (§6). `CROUTE-0001` is now a
permanent, immutable record whose validity does not lapse with either clock.

**The next selection is what consumes freshness**, through ELIG-6. Neither clock
was raced and neither was renewed.

---

## 11. G11-K deferred hardening findings

Both carried forward **unpatched**, per ruling, as dedicated RED-first
checkpoints:

1. **Withdrawn-binding route admission** — `create_route` reads the named
   record's `lifecycle_state`, and a binding root's state is frozen at
   `admitted`, so a route naming a withdrawn binding's root is accepted.
   Selection compensates with `instance-not-admitted`.
2. **Route predecessor / head enforcement** — `create_route` does not require a
   superseded route to be the chain head, so a fork is creatable;
   `selection._chain_heads` then refuses the whole traversal as
   `route-chain-unreadable`.

**`CROUTE-0001` exercises neither**, verified against the persisted records:

```
route supersedes          : None       -> the head-ness path never runs
candidate lifecycle_state : admitted
candidate supersedes      : None       -> CINST-000001 is its own binding root
instance records on disk  : 1          -> single-record lifecycle chain
```

No STOP condition arose.

---

## 12. Actions NOT performed

- **No `CROUTE-0002`.** Exactly one route exists.
- **No `CADV-000003`, no `CINST-000002`, no `CSEL-000001`.**
- **Nothing withdrawn or retired.**
- **No package staged, no capability invoked.**
- **Trust, Artifact and Platform Evidence not mutated** (§9).
- **Runtime not reinstalled**; installed surface byte-identical.
- **Root Authority not mounted; sudoers not modified.**
- **Health Runtime not begun; no TrustGateway cutover.**
- **Neither G11-K deferred behaviour patched** (§11).
- **No source or test change.** This checkpoint commits a report and nothing
  else.
- **No retry, no modified input, no repair** — the write ran once and returned
  the exact authorised identity and digest.
- **No privileged operation, no `sudo`.** The write ran as uid 1000 against a
  store owned by uid 1000; the operator's privileged act was the G11-L freeze,
  already complete.
- **No secrets recorded.**

---

## 13. Readiness for the `CADV-000003` renewal

**Ready.** The fabric now holds a complete governed chain from capability
definition to route:

```
CAPDEF-0001 → CCON-0001 → CPKG-0001
                              ↓
CHOST-0001 (HOST-0001) → CADV-000001 ⇠superseded⇠ CADV-000002
                                                       ↓
                                                 CINST-000001
                                                       ↓
                                                  CROUTE-0001
```

`CSEL-000001` is the only remaining object, and it is the one that consumes
advertisement freshness. On current timing the intended chain is:

1. **`CADV-000003` supersedes `CADV-000002`** — the G11-F renewal path, proven
   and unaffected by the deferred findings. Its own preflight works.
2. **`CINST-000002` supersedes `CINST-000001`**, admitted against
   `CADV-000003`.
3. **A route naming `CINST-000002`** — note this will exercise route
   supersession (`CROUTE-0002 supersedes CROUTE-0001`, `route_version 2`), which
   is the first time G11-K finding (2) becomes reachable in production. **That
   ordering should be decided before the route step**, not during it.
4. **Fresh selection preflight → `CSEL-000001`.**

Two carried notes for the renewal ceremony:

- **`register-advertisement` still has no permanent preflight coverage**
  (G11-K §10, one of the remaining five). Its production preflight worked in
  G11-F, but nothing pins it. Worth closing before or alongside the renewal, on
  the G11-K pattern.
- **Step 3 is where finding (2) first matters.** A route supersession whose
  predecessor is the head is fine; the gap only appears with a non-head
  predecessor. A dedicated hardening checkpoint before step 3 would remove the
  question entirely.

---

## Appendix A — commands executed

The write is the one mutating command; everything else is read-only. **No
`sudo`.**

```bash
# Mandatory pre-write checks
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
stat -c '%n %U:%G %a %s' /etc/kyri/fabric/croute-0001.json
sha256sum /etc/kyri/fabric/croute-0001.json
python3 -c "import json;json.load(open(...))"
cmp /etc/kyri/fabric/croute-0001.json <the G11-L candidate>
ls -1 /etc/kyri/fabric/ | grep -c '^croute-'          # exactly 1
python3 -c "<inspect_records, read-only>"
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )   # baseline
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )     # baseline

# Final approved-boundary preflight
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0001.json --approved-directory /etc/kyri/fabric

# THE AUTHORISED WRITE  (run once)
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0001.json --approved-directory /etc/kyri/fabric

# Post-write verification
cat  /var/lib/kyri/fabric/capability-routes/CROUTE-0001.yaml
sha256sum /var/lib/kyri/fabric/capability-routes/CROUTE-0001.yaml
cat  /var/lib/kyri/fabric/sequences/capability-route.seq ; printf '1\n' | sha256sum
python3 -c "<field-by-field verification of the persisted record>"
python3 -c "<inspect_records>" ; python3 -m tools.trust.cli validate-store ...
<per-path manifests re-taken and diffed against the baselines>
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001   capability   kyri-execution-boundary-verification
     │
CCON-0001     contract 1.0.0
     │
CPKG-0001     package 1.0.0  →  tree:kyri-execution-boundary-verification/1.0.0
     │
CHOST-0001    host, node HOST-0001, on-premises, internal, in-service
     │
     ├── CADV-000001   expired, superseded, retained as history
     │        ↑ supersedes
     └── CADV-000002   current head, fresh until 2026-08-29T09:24:51-05:00
                  │
                  ▼
            CINST-000001   admitted until 2026-08-29T13:46:27-05:00
                           trust TREC-000002 (package) + TREC-000001 (host)
                           scope CAPDEF-0001 / execute / internal / HOST-0001
                  │
                  ▼
            CROUTE-0001    NEW, this ceremony
                           class  CAPDEF-0001 / CCON-0001 @ 1.0.0 / internal
                           locality local-only  -> selection must prove HOST-0001
                           candidates [CINST-000001], declared order
                           version 1, supersedes nothing, no overlap
                           no Trust consumed, no advertisement referenced
                           digest 6bf6aa0f…48707

            CSEL           ABSENT  <- the only object left, and the one that
                                      consumes advertisement freshness

THE WRITE ADDED EXACTLY TWO PATHNAMES:
    capability-routes/CROUTE-0001.yaml
    sequences/capability-route.seq        absent -> 1
Nothing else in the Fabric changed. Trust, Artifact, Evidence and the
installed runtime are byte-identical.
```
