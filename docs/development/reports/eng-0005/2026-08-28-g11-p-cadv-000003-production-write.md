# ENG-0005 G11-P — CADV-000003 Production Renewal Write and Independent Verification

**Date:** 2026-08-28
**Checkpoint:** G11-P
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Perform the separately authorised production write of
`CADV-000003` from the frozen, reviewed operator input; verify the immutable
successor independently; record the ceremony.

**Outcome: ACCEPTED.**

```
outcome         accepted
reason          null
record_id       CADV-000003
record_kind     capability-advertisement
request_digest  sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
```

**`CADV-000003` is the unique current advertisement head.** All three chain
queries resolve to it, and `CADV-000002` is superseded without being touched.

- Frozen input verified **byte-identical** to the retained G11-O candidate,
  not merely digest-equal (§3).
- Final approved-boundary preflight matched all eight required values (§4).
- Persisted record verified across **18 fields** (§6).
- `capability-advertisement.seq` is exactly `3`, corroborated by digest (§7).
- Chain head verified four ways; **no `superseded_by` backlink** created (§8).
- Fabric `status: reported`, no defects; Trust `valid: true`, `problems: []` (§10).
- **`CINST-000001` is byte-identical and still bound to `CADV-000002`** (§11).

**The mutation accounting distinguishes an addition from a replacement** (§9),
which the brief specifically asked for and which the structural manifest alone
would have hidden.

---

## 2. Starting authority and production state

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | same | PASS |
| HEAD | `d1ae643eed358ad7c757f9e87e9a3358dcee7a80` | same | PASS |
| Origin contains HEAD | yes | `origin/arch/eng-0005-execution-transition` | PASS |
| Worktree | clean, nothing staged, nothing untracked | clean | PASS |

**Before the write:**

```
CAPDEF 1  CCON 1  CPKG 1  CHOST 1  CADV 2  CINST 1  CROUTE 1  CSEL 0
capability-advertisement.seq = 2
CADV-000003.yaml destination : ABSENT

advertisement_head(CADV-000001) = CADV-000002
advertisement_head(CADV-000002) = CADV-000002      <- head, R4 satisfiable

Fabric  status: reported, no defects
Trust   valid: true, problems: []
Runtime 57 objects        Root Authority: unmounted
```

Per-path baseline captured: **25 structural entries, 16 files** — the basis for
§9.

---

## 3. Frozen input verification

```
path      /etc/kyri/fabric/cadv-000003.json
owner     root:cschott
mode      0640
size      671
sha256    66b2c197d700502a9c2c3d5589309686b69aa9ef8249245d92746313b7ecbb26
JSON      parses
```

Every value matches the ceremony authority. Additionally:

- **`cmp` against the retained G11-O candidate: BYTE-IDENTICAL.** Digest
  equality alone would not have distinguished a re-serialisation that happens to
  hash the same; byte identity does.
- **Exactly one `cadv-000003.json`** exists in the approved directory.

---

## 4. Final approved-boundary preflight

Run from `/etc/kyri/fabric` immediately before the write:

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

Checked value by value:

```
outcome              OK   'preflight'
would_accept         OK   True
predicted_record_id  OK   'CADV-000003'
destination_exists   OK   False
mutated              OK   False
rehearsal_reason     OK   None
request_digest       OK   'sha256:b86457da…282c5d'
request_id           OK   'g11o-register-advertisement-…-supersedes-cadv-000002'

ALL FINAL CHECKS PASS -- write authorised
```

---

## 5. The production write

Executed exactly as authorised:

```bash
cd /opt/schott-platform

python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 \
  --expected-gid 1000 \
  --input-file cadv-000003.json \
  --approved-directory /etc/kyri/fabric
```

**Raw outcome, verbatim:**

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CADV-000003",
  "record_kind": "capability-advertisement",
  "request_digest": "sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d",
  "request_id": "g11o-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000002"
}
```

**exit 0.** Run once; no retry, no modified input, no repair.

---

## 6. The persisted record

`/var/lib/kyri/fabric/capability-advertisements/CADV-000003.yaml` —
`cschott:cschott`, mode `0600`, 924 bytes, written `2026-08-28 19:19`:

```yaml
advertised_resource_profile:
  architecture: x86-64
advertisement_id: CADV-000003
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
  - CADV-000002
  reason_category: supersession
  recorded_at: '2026-08-28T16:19:19-05:00'
  request_digest: sha256:b86457dac0f2179f23d9bb7bcc615f21e4c4e27720551f0cf5947db28f282c5d
  request_id: g11o-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000002
  trust_evidence_references: []
kind: capability-advertisement
observed_at: '2026-08-28T16:19:19-05:00'
provenance:
  class: declared
  recorded_at: '2026-08-28'
  source: docs/decisions/ADR-0012-distributed-capability-fabric.md
satisfied_contract_versions:
- 1.0.0
schema_version: schott-platform/v1
supersedes: CADV-000002
valid_until: '2026-08-30T16:19:19-05:00'
```

```
CADV_SHA256  f2b48c2efbe6c1f547f538c6686b1dd0aa24fcbee664ac7ea08c6f5aa2e7116d
```

### Field-by-field verification — 18 of 18

```
PASS: advertisement_id == CADV-000003
PASS: capability_host_id == CHOST-0001
PASS: capability_package_id == CPKG-0001
PASS: contract_id == CCON-0001
PASS: satisfied_contract_versions == [1.0.0]
PASS: advertised_resource_profile == {architecture: x86-64}
PASS: observed_at == 2026-08-28T16:19:19-05:00
PASS: valid_until == 2026-08-30T16:19:19-05:00
PASS: validity duration == exactly 48 hours
PASS: supersedes == CADV-000002
PASS: actor == CHOST-0001
PASS: no approving_authority
PASS: request_id == reviewed
PASS: request_digest == reviewed
PASS: reason_category == supersession
PASS: evidence references the predecessor
PASS: no Trust evidence invented
PASS: no superseded_by on the successor
```

Two are worth naming. **`trust_evidence_references` is empty** — not an omission
but the architecture: `register_advertisement` takes no trust store, because an
advertisement is a self-report that grants nothing. And **`approving_authority`
is `null`** — supplying one would have refused, because recording an approver
would turn a self-report into an approval.

---

## 7. Sequence

```
/var/lib/kyri/fabric/sequences/capability-advertisement.seq
raw = '3\n'    stripped == '3' : True
```

Corroborated independently: `printf '3\n' | sha256sum` equals the observed
`1121cfcc…4302a2`, and the prior content hashed `53c234e5…dd3c3` = `sha256("2\n")`.

---

## 8. Chain-head verification

```
advertisement_head(CADV-000001) = CADV-000003   OK
advertisement_head(CADV-000002) = CADV-000003   OK
advertisement_head(CADV-000003) = CADV-000003   OK

unique current head (records nothing supersedes): ['CADV-000003']   OK
```

Four independent confirmations, the last derived by set difference over every
record's `supersedes` rather than by the helper — so the helper and the raw data
agree.

```
CADV-000002.superseded_by : None
```

**No backlink was created, and none was expected.** Supersession is stated
forward by the successor and read backwards; an immutable record that acquired a
field later would not have been immutable. The lineage is now:

```
CADV-000001  ⇠superseded⇠  CADV-000002  ⇠superseded⇠  CADV-000003  (head)
```

---

## 9. Exact mutation accounting

Per-path manifests taken immediately before and after. **Every changed pathname,
accounted for — and the two kinds of change distinguished.**

### Structural entries — one addition, zero removals

```
> f 600 1000:1000 924 ./capability-advertisements/CADV-000003.yaml
```

### File contents — one addition **and one replacement**

```
> f2b48c2efbe6c1f547f538c6686b1dd0aa24fcbee664ac7ea08c6f5aa2e7116d  capability-advertisements/CADV-000003.yaml
< 53c234e5e8472b6ac51c1ae1cab3fe06fad053beb8ebfd8977b010655bfdd3c3  sequences/capability-advertisement.seq
> 1121cfccd5913f0a63fec40a6ffd44ea64f9dc135c66634ba001d10bcf4302a2  sequences/capability-advertisement.seq

sha256("2\n") = 53c234e5e8472b6ac51c1ae1cab3fe06fad053beb8ebfd8977b010655bfdd3c3   <- old
sha256("3\n") = 1121cfccd5913f0a63fec40a6ffd44ea64f9dc135c66634ba001d10bcf4302a2   <- new
```

| Mutation | Kind | Evidence |
|---|---|---|
| `capability-advertisements/CADV-000003.yaml` | **addition** | one `>` in both manifests, 924 bytes, `0600` |
| `sequences/capability-advertisement.seq` `2` → `3` | **replacement in place** | `<` **and** `>` in the content manifest |

**The sequence is a replacement, not an addition, and it deliberately does not
appear in the structural diff.** Its type, mode, owner, path and *size* are all
unchanged — `"2\n"` and `"3\n"` are both two bytes — so a manifest of structural
attributes cannot see it. Only the content manifest can. Describing it as an
addition would have been wrong, and reporting only the structural diff would
have hidden the change entirely.

### Nothing else moved

```
CADV-000001  cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195   UNCHANGED
CADV-000002  555f9a8d35c6cbd92ccb3041a6ed2946809f3704d0a320b3d7ae198320722454   UNCHANGED
CINST-000001 92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729   UNCHANGED
CROUTE-0001  6bf6aa0f06ff13e9787f7313d17f12f11d61de07b3cf4b9b8e26a7f191c48707   UNCHANGED
Trust        cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39   UNCHANGED
Artifact     30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f   UNCHANGED
Evidence     227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b   UNCHANGED
Runtime      80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b   UNCHANGED
```

**No pre-existing governed record changed. No file was removed.** No
request-identity side file exists or was created — request identity rides the
record's own evidence.

---

## 10. Inventory and validation

| Kind | Count | Required | |
|---|---|---|---|
| `capability-definitions` | 1 | 1 | OK |
| `capability-contracts` | 1 | 1 | OK |
| `capability-packages` | 1 | 1 | OK |
| `capability-hosts` | 1 | 1 | OK |
| **`capability-advertisements`** | **3** | **3** | **OK** |
| `capability-instances` | 1 | 1 | OK |
| `capability-routes` | 1 | 1 | OK |
| `capability-selections` | 0 | 0 | OK |

```
Fabric  status: reported   defects: none
Trust   valid: true   problems: []
        audit 4, authority 1, decision 2, evidence 7, lineage 3, record 2
Runtime 57 objects, 9-file Fabric closure
CGEN    CGEN-000000000001, digest fc9a3ec3…0163   (unchanged)
Root Authority : unmounted
```

---

## 11. ⚠ CADV-000003 DOES NOT RENEW CINST-000001

**Proven, not asserted.**

```
CINST-000001 sha256           92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729
pre-write baseline            92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729
BYTE-IDENTICAL                True

advertisement_id              CADV-000002     <- still, NOT CADV-000003
admitted_until                2026-08-29T13:46:27-05:00
lifecycle_state               admitted
effective_scope               CAPDEF-0001 / execute / internal / HOST-0001
evidence.request_digest       sha256:7bd24c86…49da1a

bound to CADV-000002          True
NOT bound to CADV-000003      True
```

The record is byte-identical, so **nothing** about it changed — not its
`advertisement_id`, not its `admitted_until`, not its evidence, not its
effective scope, not its lifecycle state.

This follows from source (G11-N Q8): `register_advertisement` contains **zero**
references to `capability-instance`. Records are immutable, and an instance is
permanently bound to the advertisement that admitted it (G11-A1).

**What `CADV-000003` restores is a fresh advertisement head, and nothing else.**
When `CADV-000002` lapses at `2026-08-29T09:24:51-05:00`, `CINST-000001` becomes
permanently ineligible under ELIG-6 — and the existence of a fresh head does not
change that. Eligibility through the new advertisement requires a **new admitted
binding**:

```
CINST-000002 — the next dependency.
```

`CROUTE-0001` is likewise unchanged and still names `CINST-000001`, which is why
G11-N's answer **B** stands: a `CROUTE-0002` will be required once
`CINST-000002` exists.

---

## 12. The 48-hour window — ceremony policy, restated

> **CADV-000003 uses a reviewer-authorised 48-hour ENG-0005 bootstrap validity
> window. The duration remains ceremony policy only and must not be inferred as
> a platform default.**

The persisted record carries `observed_at 2026-08-28T16:19:19-05:00` and
`valid_until 2026-08-30T16:19:19-05:00` — a delta of exactly 48 hours, verified
in §6.

**Nothing was encoded.** No constant, config value, schema restriction or
runtime change exists for this duration, consistent with G11-N's finding that
source constrains only *ordering* and carries no minimum, maximum or default.

---

## 13. Clock state

```
observed at                    2026-08-28T19:20:24-05:00

CADV-000002  (superseded)      2026-08-29T09:24:51-05:00   14h 04m   still within window
CADV-000003  (current head)    2026-08-30T16:19:19-05:00   44h 58m   live
CINST-000001                   2026-08-29T13:46:27-05:00   18h 26m   admitted
```

**`CADV-000002`'s eventual expiry is not an error.** It is superseded; the head
is `CADV-000003`, and a superseded advertisement lapsing is ordinary history.

**And the existence of `CADV-000003` does not imply `CINST-000001` is eligible
under it** (§11). The instance names `CADV-000002` permanently.

---

## 14. Actions NOT performed

- **No `CADV-000004`.** Exactly three advertisements exist.
- **No `CINST-000002`, no `CROUTE-0002`, no `CSEL-000001`.**
- **`CINST-000001` not modified** — byte-identical (§11).
- **`CROUTE-0001` not modified** — byte-identical.
- **Nothing withdrawn or retired.**
- **Route-head enforcement not patched; withdrawn-binding routing not patched.**
- **Trust, Artifact and Platform Evidence not mutated.**
- **Generation 11 not reinstalled; sudoers untouched; Root Authority not
  mounted.**
- **No package staged, nothing invoked.**
- **ENG-0006 not begun; no TrustGateway cutover.**
- **No source or test change.** This checkpoint commits a report and nothing
  else.
- **No retry, no modified input, no repair** — the write ran once and returned
  the exact authorised identity and digest.
- **No privileged operation, no `sudo`.** The write ran as uid 1000 against a
  store owned by uid 1000; the operator's privileged act was the G11-O freeze,
  already complete.
- **No secrets recorded.**

---

## 15. Readiness for `CINST-000002` preparation

**Ready to prepare.** The fabric now holds a fresh advertisement head with 45
hours of runway, and `admit-instance` preflight has permanent coverage (G11-H),
so the ceremony can be rehearsed and preflighted exactly as `CINST-000001` was.

### Next questions, with what is already established

The brief asks these be documented rather than answered by doing the work. Where
prior checkpoints already settled a point from source, it is stated as settled —
re-deriving it would be theatre.

| Question | Status |
|---|---|
| **Is `admitted_until` duration architecture or ceremony policy?** | **Settled: ceremony policy.** G11-G §12 found no committed authority sets it; the schema requires the field and declares no duration; source imposes only ordering (`admitted_until > admitted_at`, `evaluated_at < admitted_until`). R17 ruled 24 hours for `CINST-000001` as bootstrap policy. **`CINST-000002` needs its own explicit ruling** — and note the 24h/48h asymmetry now in play: a 24-hour admission under a 48-hour advertisement leaves the binding expiring first. |
| **Does `CINST-000002` supersede `CINST-000001`?** | **Available and lawful.** `admit_instance` accepts `supersedes` with four rules: the prior must resolve, not already be superseded (`supersedes-already-superseded`), be `admitted` (`supersedes-not-admitted`), and share capability, contract **and** package (`supersedes-different-{capability,contract,package}`). `CINST-000001` satisfies all four today. **Whether to supersede or admit fresh is an operator decision**, not a source constraint. |
| **Is it a new binding root?** | **Settled: yes.** `LIFECYCLE_CATEGORIES = ('withdrawal','retirement')`; `admit_instance` files a supersession as `reason_category="supersession"`, which is not in that set, so `_binding_root(CINST-000002) == CINST-000002`. This is exactly why G11-N answered **B** — a route naming `CINST-000001` cannot represent the successor. |
| **Same Trust records?** | **Yes, and they remain valid.** `TREC-000002` (package) and `TREC-000001` (host) both carry `expires_at: null`, `state: trusted`. |
| **Refreshed Trust evaluation, or reuse?** | **Re-evaluated, not reused.** `admit_instance` calls `_verified_standing(trust_store, …, evaluated_at, domain)` for both domains at the body's own `evaluated_at`. The *records* are reused; the *verdict* is recomputed at the new instant, including scope-window checks. |
| **Changed resource profile?** | **No.** `verified_resource_profile` must **equal** `CHOST-0001.verified_resource_profile` exactly — `{architecture: x86-64}`. Any additional dimension refuses `resource-claim-not-verified`. |
| **Lifecycle-preflight coverage before the ceremony?** | **Already covered — not a blocker.** G11-H added `admit-instance --preflight` end to end, including an explicit assertion that a *superseding* admission still rehearses to preflight. |

### The one genuinely open item

**The `admitted_until` duration for `CINST-000002`.** Everything else above is
either settled from source or an ordinary operator choice. A ruling should be
made deliberately rather than inherited, and should account for the interaction
with the 48-hour advertisement: an admission window that outlives the
advertisement produces the R17 tail (admitted but not eligible), and one that
expires first ends the binding while the advertisement is still fresh.

---

## Appendix A — commands executed

The write is the one mutating command; everything else is read-only. **No
`sudo`.**

```bash
# Mandatory pre-write checks
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
git branch -r --contains d1ae643
stat -c '%n %U:%G %a %s' /etc/kyri/fabric/cadv-000003.json
sha256sum /etc/kyri/fabric/cadv-000003.json ; python3 -c "import json;json.load(...)"
cmp /etc/kyri/fabric/cadv-000003.json <retained G11-O candidate>     # byte-identical
python3 -c "<advertisement_head before>" ; python3 -c "<inspect_records>"
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )

# Final approved-boundary preflight
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000003.json --approved-directory /etc/kyri/fabric

# THE AUTHORISED WRITE  (run once)
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000003.json --approved-directory /etc/kyri/fabric

# Post-write verification
cat /var/lib/kyri/fabric/capability-advertisements/CADV-000003.yaml
sha256sum ... ; python3 -c "<18-field verification>"
python3 -c "<advertisement_head x3 + unique-head by set difference>"
cat sequences/capability-advertisement.seq ; printf '2\n'|sha256sum ; printf '3\n'|sha256sum
python3 -c "<CINST-000001 byte identity and advertisement_id>"
<per-path manifests re-taken and diffed; authorities re-digested>
python3 -c "<inspect_records>" ; python3 -m tools.trust.cli validate-store ...
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001 → CCON-0001 → CPKG-0001
                              │
CHOST-0001 (node HOST-0001) ──┤
                              │
  CADV-000001 ⇠superseded⇠ CADV-000002 ⇠superseded⇠ CADV-000003   ← NEW, head
                                  │                     valid to 2026-08-30T16:19:19-05:00
                                  │                     digest f2b48c2e…7116d
                                  ▼
                            CINST-000001   UNCHANGED, byte-identical
                                           advertisement_id = CADV-000002  ← still
                                           admitted_until 2026-08-29T13:46:27-05:00
                                  │
                                  ▼
                            CROUTE-0001    UNCHANGED
                                           candidates [CINST-000001]

                            CSEL           ABSENT

THE WRITE CHANGED EXACTLY TWO PATHNAMES:
    capability-advertisements/CADV-000003.yaml     ADDED       (924 bytes)
    sequences/capability-advertisement.seq         REPLACED    2 -> 3
        ^ invisible to a structural manifest: same type, mode, owner, size.
          Only the content manifest sees it.

Nothing else moved. CADV-000001, CADV-000002, CINST-000001, CROUTE-0001,
Trust, Artifact, Evidence and the installed runtime are all byte-identical.

AND THE RENEWAL RESCUES NOTHING:
    CINST-000001 still names CADV-000002 and will go ineligible when that
    lapses tomorrow morning. CINST-000002 is the next dependency.
```
