# ENG-0005 G11-AZ-C — CSEL-000002 preparation

**Status: prepared, awaiting operator freeze.** No production byte was written by
this preparation. The production Fabric content manifest is
`ef054d64e48d74b5b4dd1d8d8294f0add7773165ab9c975daf1b375f2ebcd8f5` before and
after every check below — the post-AZ-B value, unchanged.

Follows **[G11-AZ-B](2026-09-03-g11-az-b-croute-0003-production-write.md)**,
which accepted the `CROUTE-0003` production write. Every value here is derived
from the **live written** route, never from `CSEL-000001` and never from the
draft AZ-A §8 sketched before the route existed.

Branch `arch/eng-0005-execution-transition`, HEAD `2037854`.

---

## 1. Why this could not have been prepared earlier

AZ-A §8 established it and the live store now confirms it: a selection input
names a **request class**, never a `route_id`. The route is resolved from that
class at selection time, so the same bytes meant something different yesterday.

Against production **before** the route write, the resolution produced
`selected_instance_id: null` and would have stored a `selection-refusal` naming
`CROUTE-0002`. Against production **now**, the same class resolves
`CROUTE-0003`. The identifier `CSEL-000002` would have been permanently spent on
a refusal record. It was not, and it is still free — §7.

## 2. The candidate is freshly derived, not reused

The AZ-A draft was **not** carried forward. Both the request identity and the
instants were re-derived for this ceremony:

| | AZ-A draft (never frozen, never written) | this candidate |
| --- | --- | --- |
| `request_id` | `g11az-select-…-host-0001` | `g11azc-select-…-host-0001-croute-0003` |
| `recorded_at` / `evaluated_at` | `2026-09-03T06:44:11-05:00` | **`2026-09-03T14:05:40-05:00`** |
| SHA-256 | — | **`5e3b3be1…ba870e`** |

The draft's request digest was `sha256:65fe4741…c338088`; this candidate's is
`sha256:ec1cbe8a…43007f`. **Different bytes, different digest**, so the two are
distinguishable by inspection and the draft cannot be frozen by mistake.

The request identity names the route it was derived against, which the digest
itself cannot witness — see §5.

## 3. The request class, read from the live route head

Every dimension taken from `CROUTE-0003` as stored, not from `CSEL-000001`:

| field | value | authority |
| --- | --- | --- |
| `capability_id` | `CAPDEF-0001` | `CROUTE-0003.capability_id` |
| `contract_id` | `CCON-0001` | `CROUTE-0003.contract_id` |
| `accepted_contract_versions` | `["1.0.0"]` | `CROUTE-0003.accepted_contract_versions` |
| `data_classification` | `internal` | `CROUTE-0003.data_classification` |
| `locality` | `local-only` | `CROUTE-0003.locality` |
| `local_node_identity` | `HOST-0001` | `CHOST-0001.node_identity_reference` |

`_resolve_route` matches a class **exactly** — same capability, contract,
accepted version set, classification and locality. Nothing is widened, and two
current routes for one class would refuse as `route-ambiguous` rather than
resolve. There is exactly one route chain head, so no ambiguity exists.

## 4. Resolution against production, read directly

Not inferred from the preflight, which does not report the route it chose. The
released resolver was run against the live store:

```
route chain heads      : ['CROUTE-0003']
resolved route_id      : CROUTE-0003
resolved route_version : 3
candidate_instances    : ['CINST-000003']
```

**`CSEL_ROUTE = CROUTE-0003`.**

## 5. Live preflight

Read-only against production:

```
predicted_record_id : CSEL-000002
destination         : /var/lib/kyri/fabric/capability-selections/CSEL-000002.yaml
destination_exists  : false
would_accept        : true
mutated             : false
selected_instance_id: CINST-000003
request_digest      : sha256:ec1cbe8ab042bb3c728eea56d3487ea4eab1e29b114f43e77b1538619d43007f
```

**Read `would_accept` and `selected_instance_id`, not `outcome`.** `outcome`
reads `preflight` whether the rehearsal selected an instance, selected nothing,
or refused — AZ-A §8 showed a `null` selection reported the same `outcome` as a
successful one.

**The digest does not witness the route.** It covers the caller's inputs, and
the caller supplies no `route_id`. `sha256:ec1cbe8a…43007f` would be identical
if this input were run against a store whose head were still `CROUTE-0002`. The
operator must therefore verify `selected_instance_id: CINST-000003` in the
preflight output, and `route_id: CROUTE-0003` in the written record — the digest
alone cannot distinguish a correct selection from one bound to a stale route.

## 6. Fixture rehearsal

A copy of the live store, `diff -r` clean against production before the write.

**The fixture write succeeded**, producing:

```
selection_id          CSEL-000002
route_id              CROUTE-0003
route_version         3
selected_instance_id  CINST-000003
selection_reason      first eligible candidate in declared order
reason_category       selection
considered_candidates [CINST-000003]
excluded_candidates   []
local_node_identity   HOST-0001
request_class         CAPDEF-0001 / CCON-0001 / [1.0.0] / internal / local-only
causal_references     [CROUTE-0003, CINST-000003]
selected_at           2026-09-03T14:05:40-05:00
```

`reason_category: selection`, **not** `selection-refusal`, and
`excluded_candidates` is **empty** — nothing was considered and rejected. The
fixture Fabric validated with **zero findings**, counts 4 / 3 / 3 / 2.

## 7. Eligibility re-evaluated at the selection instant

Not carried forward from AZ-B. Re-run through the released engine at the
candidate's own `evaluated_at`:

```
evaluated_at : 2026-09-03T14:05:40-05:00
eligible     : true
unmet        : []
reasons      : []
ELIG-1 .. ELIG-12   all met
```

`CSEL_ELIGIBILITY = PASS`. Every current selection condition is met by
`CINST-000003` at the instant the selection declares.

## 8. The candidate

| | |
| --- | --- |
| bytes | **605** |
| SHA-256 | `5e3b3be15fe7bd40e8f47b29516c5373296cd729ff95e9d733de3204d8ba870e` |
| request digest | `sha256:ec1cbe8ab042bb3c728eea56d3487ea4eab1e29b114f43e77b1538619d43007f` |
| destination | `/etc/kyri/fabric/csel-000002.json`, `root:cschott 0640` |
| `recorded_at` / `evaluated_at` | `2026-09-03T14:05:40-05:00` |

```json
{
  "request_id": "g11azc-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0003",
  "actor": "primary-platform-operator",
  "recorded_at": "2026-09-03T14:05:40-05:00",
  "evaluated_at": "2026-09-03T14:05:40-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "data_classification": "internal",
  "locality": "local-only",
  "local_node_identity": "HOST-0001",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-03"
  }
}
```

`approving_authority` is deliberately **absent**. `CSEL-000001` stores
`approving_authority: null`, and a selection is a resolution rather than an
approval.

## 9. Operator block — freeze only

Fail-if-exists. It writes the reviewed input and preflights it. It performs
**no** Fabric write.

```bash
bash <<'FREEZE_CSEL'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/csel-000002.json
REVIEWED=5e3b3be15fe7bd40e8f47b29516c5373296cd729ff95e9d733de3204d8ba870e

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11azc-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0003",
  "actor": "primary-platform-operator",
  "recorded_at": "2026-09-03T14:05:40-05:00",
  "evaluated_at": "2026-09-03T14:05:40-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "data_classification": "internal",
  "locality": "local-only",
  "local_node_identity": "HOST-0001",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-03"
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
python3 -m tools.fabric.cli select \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file csel-000002.json --approved-directory /etc/kyri/fabric --preflight
FREEZE_CSEL
```

Expect 605 bytes at `5e3b3be1…ba870e`, and a preflight reporting
`would_accept: true`, `mutated: false`, `predicted_record_id: CSEL-000002`,
**`selected_instance_id: CINST-000003`**, and request digest
`sha256:ec1cbe8a…43007f` — the same digest as §5.

**If `selected_instance_id` is `null`, stop.** That would mean the class resolved
to a route with no eligible candidate, and writing it would spend `CSEL-000002`
on a refusal record.

The Fabric write is **not** in this block. It is authorised separately.

## 10. Production state

```
CSEL-000002 (record)               absent
seq(capability-selection)          1
/etc/kyri/fabric/csel-000002.json  absent
CSEL-000001                        unchanged, e08a4df4…e79bb
CROUTE head                        CROUTE-0003, candidate_instances [CINST-000003]
CINST head                         CINST-000003, admitted, eligible
sudoers non-README                 0
CINV / CRES                        0 / 0
helper compatibility               compatible, 8 declared, 0 blocking
Root Authority                     unmounted
```

`PRODUCTION_CSEL_WRITE = NOT_PERFORMED`.
`PRODUCTION_INVOKE_AUTHORISED = NO`.

`CSEL-000001` is historical and immutable. Route-head movement does not
invalidate it — selection eligibility is rechecked at use — and it is not
modified by this preparation or by the write that follows.

## 11. Next

1. Operator freezes the reviewed `CSEL-000002` input with §9 and returns the
   output.
2. Independent verification of the frozen input, then a separately authorised
   single production selection write, verifying `route_id: CROUTE-0003` and
   `selected_instance_id: CINST-000003` in the **stored** record.
3. Then **G11-BA** — the narrow sudoers authority and final production
   preflight, with the launch and reconcile privileged boundaries kept separate.
4. Then **G11-BB**, the first controlled production invocation, where the first
   `CINV`/`CRES` should appear.
