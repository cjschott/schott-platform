# ENG-0005 G11-BB-W — CROUTE-0004 acceptance, and CSEL-000003 preparation

**Status: the `CROUTE-0004` write is independently verified and accepted.
`CSEL-000003` is prepared, digest-pinned, and — the point of this checkpoint —
the released resolver has been shown, before any freeze, to return
`CROUTE-0004` / v4 / `CINST-000004`. It is NOT written.**

```
CROUTE_HEAD                      CROUTE-0004    sole head by supersession
CURRENT_ELIGIBILITY              PASS           12/12, re-evaluated live
RESOLVED_ROUTE                   CROUTE-0004    v4
SELECTED_INSTANCE                CINST-000004
FABRIC_DELTA                     1 CREATE, 1 REPLACE, 0 REMOVE   (reconstructed)
CSEL_PREFLIGHT                   PASS
PRODUCTION_CSEL_WRITE            NOT_PERFORMED
FABRIC_MUTATION_FROM_PREPARATION NONE
```

> **The lease closes `2026-09-10T21:30:00-05:00` — about 1 day 15 h from this
> reading.** `CSEL-000003` and the entire `CINV-000002` ceremony must complete
> inside it, or the chain needs another renewal first. This is the first
> checkpoint where the remaining window is a scheduling constraint rather than a
> formality.

Branch `arch/eng-0005-execution-transition`.

---

## 1. The CROUTE-0004 write, verified independently

```
route_id                    CROUTE-0004
route_version               4
capability_id               CAPDEF-0001        contract_id           CCON-0001
accepted_contract_versions  [1.0.0]            locality              local-only
data_classification         internal           supersedes            CROUTE-0003
candidate_instances         [CINST-000004]     exactly one
overlap_window              absent             no carry-both cutover
evidence.reason_category    supersession
evidence.causal_references  [CAPDEF-0001, CCON-0001, CINST-000004, CROUTE-0003]
evidence.request_id         g11bbv-create-route-capdef-0001-ccon-0001-cinst-000004-supersedes-croute-0003
evidence.request_digest     sha256:7ff2065fff1a191a9be8d92ead5f06634bd4aaf22dee0e4de64bdce0dfa69103

CROUTE_STORED_SHA256        99d5cd7e1d6dbb04697d1c4f6e1a285271c68cb83072bdab98fd4162867174a0
```

Every reviewed field matches G11-BB-V §3, including the request digest the
reviewer approved. The frozen input is still on disk at the reviewed bytes:

```
/etc/kyri/fabric/croute-0004.json  root:cschott  640  678 bytes
bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda
```

### 1.1 The delta, by content reconstruction

```
CREATE   /var/lib/kyri/fabric/capability-routes/CROUTE-0004.yaml
REPLACE  /var/lib/kyri/fabric/sequences/capability-route.seq
           before  1121cfccd5913f0a63fec40a6ffd44ea64f9dc135c66634ba001d10bcf4302a2   b"3\n"
           after   7de1555df0c2700329e815b93b32c571c3ea54dc967b89e81ab73b9972b72d1d   b"4\n"
REMOVE   none

reconstructed pre-write aggregate  d550aa7ef70e30854c2291429b7174a7f4f1467501437390f7d24e1f45c50ff8
operator-reported pre-write        d550aa7ef70e30854c2291429b7174a7f4f1467501437390f7d24e1f45c50ff8   MATCH

post-write aggregate               ce6f7db2335bc8dd7b1cc19166a67531766657476d050796c1861bd2c5a33d61
```

Dropping exactly the new record and restoring exactly the route sequence
reproduces the operator-reported pre-write aggregate, so every other path is
byte-identical by construction. Corroborated by modification times:

```
2026-09-08 12:16:34.102  sequences/capability-route.seq
2026-09-08 12:16:34.108  capability-routes/CROUTE-0004.yaml
2026-09-08 12:16:34.110  capability-routes/            (directory entry)
```

```
CROUTE-0003   18d54f8a6f8201362a827c940bee3d42ea8cd792d69005a5ed96a3bdff8bb22a
              mtime 2026-09-03 14:02:40   UNCHANGED
CINST-000004  77ce6a68ede34cf2ceade4edc5be3efa591f10b71b246211057e47696a0290d9   unchanged
trust         53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   UNCHANGED

fabric validate  valid, findings []   CADV 5  CINST 4  CROUTE 4  CSEL 2
trust  validate  valid, problems []
```

### 1.2 Heads

```
capability-advertisement  seq=5  heads=[CADV-000005]
capability-instance       seq=4  heads=[CINST-000004]
capability-route          seq=4  heads=[CROUTE-0004]     next CROUTE-0005
capability-selection      seq=2  heads=[CSEL-000001, CSEL-000002]   next CSEL-000003

CROUTE-0001 v1 supersedes None         candidates [CINST-000001]
CROUTE-0002 v2 supersedes CROUTE-0001  candidates [CINST-000002]
CROUTE-0003 v3 supersedes CROUTE-0002  candidates [CINST-000003]
CROUTE-0004 v4 supersedes CROUTE-0003  candidates [CINST-000004]
```

## 2. Eligibility, re-evaluated — not inferred from the route write

Released logic, live store, at `2026-09-09T05:57:48-05:00`:

```
ELIG-1 .. ELIG-12   all met      unmet []      eligible = true
binding_root(CINST-000004) = CINST-000004
route candidate            = exactly [CINST-000004]
```

```
CURRENT_ELIGIBILITY = PASS
```

The advertisement window (`2026-09-06T21:30` → `2026-09-10T21:30`) and the
admission window (`2026-09-07T14:15` → `2026-09-10T21:30`) are both open and
close together.

## 3. CSEL-000003 — the candidate

```
CSEL_ID             CSEL-000003        (from the live sequence authority)
RECORDED_AT         2026-09-09T06:10:00-05:00
EVALUATED_AT        2026-09-09T06:10:00-05:00
CSEL_FROZEN_SHA256  700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e
CSEL_FROZEN_BYTES   605
CSEL_REQUEST_DIGEST sha256:ca00000e4d9f1dc524c5af7f28fd549c9eb48820cc7888f5a8ba2219aaf80a06
```

The request class is taken from `CROUTE-0004` field for field.

```json
{
  "request_id": "g11bbw-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0004",
  "actor": "primary-platform-operator",
  "recorded_at": "2026-09-09T06:10:00-05:00",
  "evaluated_at": "2026-09-09T06:10:00-05:00",
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
    "recorded_at": "2026-09-09"
  }
}
```

*Verbatim: extracted from this report and hashed it is `700a1390…` at 605 bytes,
and so is the heredoc in §6.*

**The body names no `route_id`.** That is why this preparation could not happen
before `CROUTE-0004` existed, and why the resolution below is separate evidence.

## 4. The resolution, proved before the freeze

Two independent measurements against the **live production store**, read-only.

**The released resolver, called directly** (`selection._resolve_route`):

```
route_id                    CROUTE-0004
route_version               4
candidate_instances         [CINST-000004]
class                       CAPDEF-0001  CCON-0001  [1.0.0]  internal  local-only
```

**The preflight of the reviewed body:**

```
would_accept            true
selected_instance_id    CINST-000004
predicted_record_id     CSEL-000003
destination_exists      false
mutated                 false
request_digest          sha256:ca00000e4d9f1dc524c5af7f28fd549c9eb48820cc7888f5a8ba2219aaf80a06
```

And the record a fixture write produces, which is what the operator will get:

```
selection_id            CSEL-000003
route_id                CROUTE-0004        route_version  4
selected_instance_id    CINST-000004
considered_candidates   [CINST-000004]
excluded_candidates     []
reason_category         selection                      <- successful selection
selection_reason        first eligible candidate in declared order
supersedes              (absent — selections carry no supersedes field)
```

```
RESOLVED_ROUTE = CROUTE-0004    RESOLVED_ROUTE_VERSION = 4
SELECTED_INSTANCE = CINST-000004
```

The fixture write returned the **same request digest** as the live preflight.

## 5. Negative battery — and the finding that governs this stage

Every row is a read-only preflight; production Fabric was byte-identical before
and after (`ce6f7db2…` → `ce6f7db2…`) and every row reports `mutated=false`.

### 5.1 `would_accept` is NOT the acceptance criterion for a selection

**A selection that cannot resolve is not refused. It is accepted, and it stores
`selected_instance_id: null`.** Measured:

| # | input | `would_accept` | `selected_instance_id` | reason |
| --- | --- | --- | --- | --- |
| — | **the reviewed candidate** | true | **CINST-000004** | — |
| S1 | wrong capability `CAPDEF-0002` | **true** | **null** | — |
| S2 | wrong contract `CCON-0002` | **true** | **null** | — |
| S3 | wrong contract version `2.0.0` | **true** | **null** | — |
| S6 | wrong `local_node_identity` `HOST-0002` | **true** | **null** | — |
| S6b | unknown `local_node_identity` `HOST-0009` | **true** | **null** | — |
| S7 | evaluated after both windows close | **true** | **null** | — |
| S4 | wrong locality `remote` | false | null | `unknown-locality` |
| S5 | wrong classification `restricted` | false | null | `unknown-data-classification` |

Only S4 and S5 refuse, and they refuse on **vocabulary** validation — a value
outside the governed enumeration — not on resolution. Every other malformed
request class is *accepted* and would spend `CSEL-000003` on a record that
selects nothing:

```
selection_reason   no route resolved for the request class
considered_candidates  []      excluded_candidates  []
```

**So the operator must read `selected_instance_id`, not `would_accept`.** The
freeze block and its expected output make that the explicit gate.

### 5.2 The premature-selection regression, executed

The hazard G11-BB-S §11.4 predicted, run here against a store rewound to the
`CROUTE-0003` head with the **reviewed body unchanged**:

| | correct store (head `CROUTE-0004`) | stale store (head `CROUTE-0003`) |
| --- | --- | --- |
| `would_accept` | true | **true** |
| `route_id` written | `CROUTE-0004` | **`CROUTE-0003`** |
| `route_version` | 4 | **3** |
| `selected_instance_id` | `CINST-000004` | **null** |
| `selection_reason` | first eligible candidate in declared order | no candidate in declared order was eligible |
| `excluded_candidates` | `[]` | `CINST-000003` — `advertisement-not-fresh`, `admission-window-expired` |
| **`request_digest`** | `sha256:ca00000e…` | **`sha256:ca00000e…` — identical** |

**The request digest is identical in both.** It covers the caller's inputs, and
`route_id` is not one of them, so it cannot witness which route a selection
bound to. That is exactly why §4 proves the resolution separately and why this
preparation was deferred until `CROUTE-0004` was verified as head.

This row is also the **no-eligible-candidate** case: the route resolved, its one
candidate was judged and excluded with reasons, and the selection still
succeeded with a null result.

### 5.3 Duplicate identity — the write is idempotent, the preflight is not

Replaying the identical body against a store where `CSEL-000003` is already
written:

```
real write   outcome=exact-replay   record_id=CSEL-000003   nothing allocated
             capability-selection.seq stays at 3, no CSEL-000004 created
preflight    would_accept=true      predicted_record_id=CSEL-000004
```

**A double-run of the write is safe** — replay is detected by `request_id` and
digest, and returns the original record. The *preflight* is the misleading one:
it peeks the next free identity rather than performing the replay lookup, so
after a completed write it predicts `CSEL-000004`. Recorded so a re-run of the
preflight is not mistaken for a second selection being needed. (The
`exact-replay` payload reports `selected_instance_id: null`; it echoes the
replay, not the original decision.)

## 6. The operator freeze block

**It writes exactly one path, `/etc/kyri/fabric/csel-000003.json`, and performs
no Fabric write.** `root:cschott 0640` matches all nineteen accepted inputs
already there.

Verified before publication: the heredoc was extracted from this report and
hashed — `700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e` at
605 bytes, byte-identical to the rehearsed candidate. Each refusal arm was
exercised against a real body.

```bash
bash <<'FREEZE_CSEL'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/csel-000003.json
REVIEWED=700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e
REVIEWED_BYTES=605

# Bodies that are NOT this one, refused BY NAME. Both would be accepted by the
# engine -- a selection body is just a request class -- and neither can be told
# from the reviewed one by request digest.
SUPERSEDED_BBS=040bfe4e03906f9764e086bbfe51ca85e7b37168f4d76e6100bf6b08b843a417
ACCEPTED_CSEL2=5e3b3be15fe7bd40e8f47b29516c5373296cd729ff95e9d733de3204d8ba870e

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

sudo test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

# A selection names no route. It resolves one at selection time, so the route
# this was reviewed against must already be the written head.
sudo test -e /etc/kyri/fabric/croute-0004.json || {
  echo "REFUSE: the CROUTE-0004 input is absent; this selection has no reviewed route"
  exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11bbw-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0004",
  "actor": "primary-platform-operator",
  "recorded_at": "2026-09-09T06:10:00-05:00",
  "evaluated_at": "2026-09-09T06:10:00-05:00",
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
    "recorded_at": "2026-09-09"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
case "${ACTUAL}" in
  "${SUPERSEDED_BBS}")
    echo "REFUSE: this is the SUPERSEDED G11-BB-S §11 candidate, not the reviewed G11-BB-W one"
    rm -f "${TMP}"; exit 1 ;;
  "${ACCEPTED_CSEL2}")
    echo "REFUSE: this is the already-accepted CSEL-000002 input"
    rm -f "${TMP}"; exit 1 ;;
esac
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }
test "$(wc -c < "${TMP}")" = "${REVIEWED_BYTES}" || {
  echo "REFUSE: rendered $(wc -c < "${TMP}") bytes, reviewed ${REVIEWED_BYTES}"
  rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- /etc/kyri/fabric AFTER ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

printf '\n--- preflight against the FROZEN input (read-only; NO Fabric write) ---\n'
printf -- '--- READ selected_instance_id, NOT would_accept. It MUST be CINST-000004. ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli select \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file csel-000003.json --approved-directory /etc/kyri/fabric --preflight \
  | tee /dev/stderr \
  | python3 -c 'import json,sys
d = json.load(sys.stdin)
if d.get("selected_instance_id") != "CINST-000004":
    print("REFUSE: preflight selected %r, reviewed CINST-000004" % (d.get("selected_instance_id"),))
    raise SystemExit(1)
print("OK: preflight resolves to CINST-000004")'

printf '\n--- production Fabric must be byte-identical to before ---\n'
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
echo "expect ce6f7db2335bc8dd7b1cc19166a67531766657476d050796c1861bd2c5a33d61  -"
FREEZE_CSEL
```

### 6.1 Expected output

```
/etc/kyri/fabric BEFORE   19 entries, newest croute-0004.json
frozen input              700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e
                          /etc/kyri/fabric/csel-000003.json  root:cschott  640  605 bytes
/etc/kyri/fabric AFTER    20 entries; csel-000003.json is the only addition
preflight                 selected_instance_id CINST-000004      <- THE GATE
                          would_accept true, mutated false,
                          predicted_record_id CSEL-000003, destination_exists false,
                          request_digest sha256:ca00000e4d9f1dc524c5af7f28fd549c9eb48820cc7888f5a8ba2219aaf80a06
                          OK: preflight resolves to CINST-000004
fabric aggregate          ce6f7db2335bc8dd7b1cc19166a67531766657476d050796c1861bd2c5a33d61
```

The `select` write is not in this block and is not authorised by this
checkpoint.

## 7. Invocation safety

No invocation-related mutation. Read-only:

```
CINV-000001 sha256   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CINV-000001 outcome  execution-prepared   adapter_identity null   selection_id CSEL-000002
                     -> permanently UNRESOLVED, resume FORBIDDEN
CINV seq 1           CRES count 0
next CINV-000002 unspent     next CRES-000001
validate_store       findings ()
```

`CINV-000001` names `CSEL-000002`, which stays exactly as written. Selections
carry no `supersedes` field, so `CSEL-000003` does not supersede it — the
historical selection is untouched evidence, and the three selections are
independent records:

```
CSEL-000001  route CROUTE-0002 v2  selected CINST-000002
CSEL-000002  route CROUTE-0003 v3  selected CINST-000003
CSEL-000003  route CROUTE-0004 v4  selected CINST-000004   (fixture only)
```

## 8. Follow-ups carried forward

None blocks `CSEL-000003`.

- **New, and the governing one:** a selection that cannot resolve is **accepted**
  with `selected_instance_id: null` (§5.1). `would_accept` does not answer the
  question an operator is asking. The freeze block enforces the real gate.
- The selection request digest does not witness the resolved route (§5.2) —
  confirmed again, now with both records in hand.
- `create_route` does not check candidate liveness, and does not validate
  `accepted_contract_versions` (G11-BB-V §5.1).
- Scope intersection silently narrows rather than refusing (G11-BB-U §6.1).
- The request digest does not cover `request_id` (G11-BB-T §3.2).
- There is no maximum validity-window policy (G11-BB-T §2.1).

## 9. Validation

No source, test or provisioning file changed; this checkpoint adds this report
only.

```
FOCUSED FABRIC SUITES   15 suites, 9589 assertions, 0 FAIL
LOCAL_QUICK             PASS
LOCAL_FULL              PASS
GITHUB CI               6/6
CLEAN CLONE             PASS

production Fabric across CROUTE verification and CSEL preparation
  ce6f7db2335bc8dd7b1cc19166a67531766657476d050796c1861bd2c5a33d61   byte-identical
production Trust
  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   byte-identical
capability-selection.seq  2      capability-selections  CSEL-000001..2
```

## 10. Next

```
PRODUCTION_CSEL_WRITE         NOT_PERFORMED
CINV_NEXT                     CINV-000002    unspent
CRES_COUNT                    0
PRODUCTION_INVOKE_AUTHORISED  NO
```

Reviewer accepts this acceptance and preparation; the operator then runs the §6
freeze block and returns its output — **including the `selected_instance_id`
line**. The `select` write is a separate authorised step, and it is the last
Fabric write before the `CINV-000002` ceremony, which must still fit inside the
window noted at the top.
