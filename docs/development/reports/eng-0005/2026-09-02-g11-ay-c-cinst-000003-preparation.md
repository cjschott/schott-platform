# ENG-0005 G11-AY-C — CINST-000003 preparation

**Status: prepared, awaiting operator freeze.** No production byte was written by
this preparation.

Follows **[G11-AY-B](2026-09-02-g11-ay-b-cadv-000004-production-write.md)**, which
accepted the `CADV-000004` production write. Every value below is derived from
the **stored** advertisement record, never from the AY-A2 candidate JSON.

Branch `arch/eng-0005-execution-transition`, HEAD `26ca46e`.

---

## 1. Identifiers, derived from the live store

| | derived from | value |
| --- | --- | --- |
| `CINST_NEXT` | `peek_next_id` on the live store | **CINST-000003** — destination absent |
| `CINST_SUPERSEDES` | the sole unsuperseded instance | **CINST-000002** |

Head derived, not assumed: of `CINST-000001` and `CINST-000002`, exactly one
appears as a `supersedes` target and exactly one does not.

The current head still names `CADV-000003` and `admitted_until
2026-08-30T16:19:19-05:00` — the expired chain this checkpoint renews.

## 2. The dependency bound, read rather than recalculated

`admitted_until` is taken from the stored production record:

```
/var/lib/kyri/fabric/capability-advertisements/CADV-000004.yaml
  valid_until: '2026-09-06T12:02:14-05:00'
```

`ADMITTED_UNTIL = 2026-09-06T12:02:14-05:00` — **equal**, which is the strongest
position the bound permits. Nothing recomputed a window; the value was read off
disk.

**The bound exercised against that stored record:**

| `admitted_until` | verdict |
| --- | --- |
| advertisement `valid_until` **+1 second** | **refused** — `admission-window-exceeds-advertisement` |
| advertisement `valid_until` **+1 hour** | **refused** — `admission-window-exceeds-advertisement` |
| **equal** | accepted |
| **12 hours shorter** | accepted |

`DEPENDENCY_BOUNDED = YES`. `R17_TAIL = ZERO` — the admission cannot outlive the
advertisement by even one second.

## 3. Every dimension re-derived from its own authority

Nothing carried over from `CINST-000002`:

| dimension | value | authority |
| --- | --- | --- |
| capability | `CAPDEF-0001` | `CPKG-0001.capability_id` |
| package | `CPKG-0001` | package record |
| host | `CHOST-0001` | host record |
| contract | `CCON-0001` | `CPKG-0001.contract_id`, cross-checked against `CCON-0001` |
| contract versions | `["1.0.0"]` | `CPKG-0001.satisfied_contract_versions`; contract declares `1.0.0` |
| resource profile | `{architecture: x86-64}` | `CHOST-0001.verified_resource_profile` |
| data classification | `internal` | `CHOST-0001.data_classification` |
| target | `HOST-0001` | `CHOST-0001.node_identity_reference` |
| host trust record | `TREC-000001` | `CHOST-0001.fabric_node_trust_record_id` |
| package trust record | `TREC-000002` | trust record whose `subject_id` is `CPKG-0001` |
| advertisement | `CADV-000004` | the stored head |

**Scope dimensions come from the trust standings, not from the prior instance.**
Both `TREC-000001` and `TREC-000002` are `state: trusted` with no expiry
(`expires_at: null`, `validity_end: null`), and both carry the same scope:

```
permitted_capabilities        [CAPDEF-0001]
permitted_operations          [execute]
permitted_data_classifications[internal]
permitted_targets             [HOST-0001]
```

The admission requests exactly that. The effective scope is the **intersection**
of package standing, host standing and the admission scope, so the request cannot
grant more than standing permits — verified in §5.

## 4. Binding-root semantics, re-derived

Not assumed. Source is explicit:

> *"A lifecycle decision continues a binding; a declared supersession starts a
> new one."*

`_binding_root` walks back only while a record's `reason_category` is in
`LIFECYCLE_CATEGORIES`, which is `('withdrawal', 'retirement')`. **`supersession`
is not one**, so the walk stops immediately.

Confirmed empirically against the fixture after the write:

```
binding root of CINST-000001 : CINST-000001
binding root of CINST-000002 : CINST-000002
binding root of CINST-000003 : CINST-000003
```

**`CINST-000003` is its own binding root.** It is not a transparent continuation
of `CINST-000002`, and nothing downstream may treat it as one.

## 5. Fixture rehearsal

A fresh copy of the live store — four advertisements including `CADV-000004`, two
instances, both routes, the selection, every sequence.

**Accepted:** `would_accept: true`, `mutated: false`, `predicted_record_id:
CINST-000003`. Fixture byte-identical before and after.

**Refused, each with its governed reason:**

| body | reason |
| --- | --- |
| references `CADV-000003` (now superseded) | `advertisement-record-superseded` |
| supersedes `CINST-000001` (already superseded) | `supersedes-already-superseded` |
| a profile the host does not verify | `malformed-operation-content` |
| package trust record that is the host's | `trust-subject-type-mismatch` |
| no `approving_authority` | `missing-approving-authority` |

The first is the one that matters most here: an admission naming the *old*
advertisement is refused now that it has been superseded, so the renewed instance
cannot silently re-bind to the expired window.

**One case accepted that is worth stating plainly.** An admission requesting
`permitted_operations: ["execute", "administer"]` is **accepted**, not refused —
and grants `["execute"]` only. The effective scope is an intersection, so asking
for more than trust permits yields less rather than an error. Verified by writing
it and reading the record back:

```
requested permitted_operations : ['execute', 'administer']
granted   permitted_operations : ['execute']
escalated                      : False
```

No escalation is possible, which is the property that matters. But the narrowing
is **silent** — an operator who asks for something standing does not permit is
not told. That is a usability edge worth knowing about rather than a defect, and
this candidate requests exactly what both standings carry, so requested and
granted are identical.

**The fixture write then succeeded**, producing `CINST-000003` with
`advertisement_id: CADV-000004`, `admitted_until 2026-09-06T12:02:14-05:00`,
`supersedes: CINST-000002`, `lifecycle_state: admitted`,
`reason_category: supersession`, both trust records cited, and the effective
scope above. The fixture Fabric validated with **zero findings**.

## 6. Live preflight

Read-only against production:

```
predicted_record_id : CINST-000003
destination         : /var/lib/kyri/fabric/capability-instances/CINST-000003.yaml
destination_exists  : false
would_accept        : true
mutated             : false
request_digest      : sha256:9ab832ff8afc9aa24c9030904ea91596bea96e58f9747fff596374c820779b24
```

`TRUST_REEVALUATION = PASS` — the rehearsal performs the same trust query the
write does, against the real trust store opened read-only, at the new
`evaluated_at`. It is never simulated and never skipped.

The request digest is identical to the fixture preflight and the fixture write.

**Non-mutation:** Fabric and Trust content manifests byte-identical across the
preflight, and identical to the post-`CADV-000004`-write manifest — so nothing
has touched the store since the accepted advertisement write.

## 7. The candidate

| | |
| --- | --- |
| bytes | **1268** |
| SHA-256 | `1e96983e7a32bd2658f1aa75183a4a8ac008d0feac898887443151472a793085` |
| request digest | `sha256:9ab832ff8afc9aa24c9030904ea91596bea96e58f9747fff596374c820779b24` |
| destination | `/etc/kyri/fabric/cinst-000003.json`, `root:cschott 0640` |
| `evaluated_at` / `admitted_at` | `2026-09-02T21:22:21-05:00` |
| `admitted_until` | `2026-09-06T12:02:14-05:00` (read from the stored record) |

```json
{
  "request_id": "g11ay-admit-instance-cpkg-0001-chost-0001-cadv-000004-supersedes-cinst-000002",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-02T21:22:21-05:00",
  "evaluated_at": "2026-09-02T21:22:21-05:00",
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
  "admission_decision_id": "eng-0005-cinst-000003-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000004",
  "supersedes": "CINST-000002",
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
  "admitted_at": "2026-09-02T21:22:21-05:00",
  "admitted_until": "2026-09-06T12:02:14-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-02"
  }
}
```

## 8. Operator block — freeze only

Fail-if-exists. It writes the reviewed input and preflights it. It performs
**no** Fabric write.

```bash
bash <<'FREEZE_CINST'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cinst-000003.json
REVIEWED=1e96983e7a32bd2658f1aa75183a4a8ac008d0feac898887443151472a793085

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11ay-admit-instance-cpkg-0001-chost-0001-cadv-000004-supersedes-cinst-000002",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-02T21:22:21-05:00",
  "evaluated_at": "2026-09-02T21:22:21-05:00",
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
  "admission_decision_id": "eng-0005-cinst-000003-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000004",
  "supersedes": "CINST-000002",
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
  "admitted_at": "2026-09-02T21:22:21-05:00",
  "admitted_until": "2026-09-06T12:02:14-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-02"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- /etc/kyri/fabric AFTER ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

printf '\n--- preflight against the FROZEN input (read-only, no Fabric write) ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file cinst-000003.json --approved-directory /etc/kyri/fabric --preflight
FREEZE_CINST
```

Expect 1268 bytes at `1e96983e…793085`, and a preflight reporting
`would_accept: true`, `mutated: false`, `predicted_record_id: CINST-000003` and
request digest `sha256:9ab832ff…0779b24` — **the same digest as §6**.

The Fabric write is **not** in this block. AY-D is authorised separately.

## 9. Production state

```
CINST-000003 (record)              absent
seq(capability-instance)           2
/etc/kyri/fabric/cinst-000003.json absent
CADV-000004 (head)                 present, valid_until 2026-09-06T12:02:14-05:00
sudoers non-README                 0
CINV / CRES                        0 / 0
helper compatibility               compatible
```

## 10. What AY-D will still not restore

After the instance write, `CROUTE-0002` will still name `CINST-000002`. The
renewed instance will **not be routable**, no service is restored, and sudoers
stays closed — so nothing could execute even if a route did resolve.

Next after AY-D: **G11-AZ** — a `CROUTE` successor, then a fresh `CSEL`.
