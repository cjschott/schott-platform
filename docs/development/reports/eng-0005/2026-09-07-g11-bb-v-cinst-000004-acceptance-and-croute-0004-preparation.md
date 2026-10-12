# ENG-0005 G11-BB-V — CINST-000004 acceptance, and CROUTE-0004 preparation

**Status: the `CINST-000004` write is independently verified and accepted, and
`CINST-000004` is eligible on production — all twelve conditions met, for the
first time since the lease expired. `CROUTE-0004` is prepared, digest-pinned and
rehearsed read-only, and NOT written.**

```
CINST_HEAD                       CINST-000004   sole head by supersession
BINDING_ROOT                     CINST-000004   its own
CURRENT_ELIGIBILITY              PASS           12/12 conditions met
FABRIC_DELTA                     1 CREATE, 1 REPLACE, 0 REMOVE   (reconstructed)
CROUTE_PREFLIGHT                 PASS
PRODUCTION_CROUTE_WRITE          NOT_PERFORMED
FABRIC_MUTATION_FROM_PREPARATION NONE
PREMATURE_SELECTION_AUTHORISED   NO
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. The CINST-000004 write, verified independently

```
instance_id             CINST-000004
capability_id           CAPDEF-0001      capability_package_id  CPKG-0001
capability_host_id      CHOST-0001       contract_id            CCON-0001
advertisement_id        CADV-000005      supersedes             CINST-000003
lifecycle_state         admitted         satisfied_contract_versions  [1.0.0]
verified_resource_profile.architecture   x86-64
admitted_at             2026-09-07T14:15:00-05:00
admitted_until          2026-09-10T21:30:00-05:00
host_trust_record_id    TREC-000001      package_trust_record_id  TREC-000002
evidence.reason_category                 supersession
evidence.trust_evidence_references       [TREC-000002, TREC-000001]
evidence.request_id     g11bbu-admit-instance-cpkg-0001-chost-0001-cadv-000005-supersedes-cinst-000003
evidence.request_digest sha256:cde47b441c4cd9d7f3e40cc554e203cd0d3e1a06e62ae799e901db30a23c4b77

CINST_STORED_SHA256     77ce6a68ede34cf2ceade4edc5be3efa591f10b71b246211057e47696a0290d9
```

**The effective scope is exactly the reviewed scope**, in all four dimensions —
the request was not narrowed:

```
permitted_capabilities          [CAPDEF-0001]
permitted_operations            [execute]
permitted_data_classifications  [internal]
permitted_targets               [HOST-0001]
```

The frozen input is still on disk at the reviewed bytes:

```
/etc/kyri/fabric/cinst-000004.json  root:cschott  640  1269 bytes
5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c
```

### 1.1 The delta, by content reconstruction

Take the current per-path digest manifest, drop exactly `CINST-000004.yaml`,
restore the instance sequence to its pre-write bytes, re-aggregate:

```
CREATE   /var/lib/kyri/fabric/capability-instances/CINST-000004.yaml
REPLACE  /var/lib/kyri/fabric/sequences/capability-instance.seq
           before  1121cfccd5913f0a63fec40a6ffd44ea64f9dc135c66634ba001d10bcf4302a2   b"3\n"
           after   7de1555df0c2700329e815b93b32c571c3ea54dc967b89e81ab73b9972b72d1d   b"4\n"
REMOVE   none

reconstructed pre-write aggregate  54dcce685e481302c20de2a7716594aef43fc4c498e9d275ce53305a333951cd
operator-reported pre-write        54dcce685e481302c20de2a7716594aef43fc4c498e9d275ce53305a333951cd   MATCH

post-write aggregate               d550aa7ef70e30854c2291429b7174a7f4f1467501437390f7d24e1f45c50ff8
```

Every other path is byte-identical by construction. Corroborated by modification
times — exactly three paths carry the write instant:

```
2026-09-07 21:04:38.516  sequences/capability-instance.seq
2026-09-07 21:04:38.528  capability-instances/CINST-000004.yaml
2026-09-07 21:04:38.530  capability-instances/            (directory entry)
```

```
CINST-000003  5b83135db80693e430d92f36a04fea837b354949a2a4bee18170da73f70c21d1
              mtime 2026-09-03 06:38:28   UNCHANGED
CADV-000005   3c9eca9f9ac0a51f164106f5c01ea78cd513b4f457ff3dedc4070ffd97c256aa   unchanged
trust         53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   UNCHANGED

fabric validate  valid, findings []   CADV 5  CINST 4  CROUTE 3  CSEL 2
trust  validate  valid, problems []
```

Route and selection sequences are untouched at 3 and 2.

### 1.2 Heads and binding root, re-derived

```
capability-advertisement  seq=5  heads=[CADV-000005]    next CADV-000006
capability-instance       seq=4  heads=[CINST-000004]   next CINST-000005
capability-route          seq=3  heads=[CROUTE-0003]    next CROUTE-0004
capability-selection      seq=2  heads=[CSEL-000001, CSEL-000002]   next CSEL-000003
```

Through released source, `LIFECYCLE_CATEGORIES = ('withdrawal', 'retirement')`:

```
CINST-000001  reason_category=instance-admission  supersedes=None          binding_root=CINST-000001
CINST-000002  reason_category=supersession        supersedes=CINST-000001  binding_root=CINST-000002
CINST-000003  reason_category=supersession        supersedes=CINST-000002  binding_root=CINST-000003
CINST-000004  reason_category=supersession        supersedes=CINST-000003  binding_root=CINST-000004
```

```
BINDING_ROOT = CINST-000004
```

**`CROUTE-0003` is the current route head** — `route_version` 3, superseded by
nothing, candidates `[CINST-000003]`, class `CAPDEF-0001 / internal /
local-only`. That is the predecessor `CROUTE-0004` must name.

## 2. Current eligibility — evaluated, not inferred

Released logic, against production, at `2026-09-07T21:06:52-05:00`:

```
ELIG-1 .. ELIG-12   all met      unmet []      eligible = true
```

```
CURRENT_ELIGIBILITY = PASS
```

Both windows are fresh — the advertisement (`observed_at 2026-09-06T21:30` →
`valid_until 2026-09-10T21:30`) and the admission (`admitted_at
2026-09-07T14:15` → `admitted_until 2026-09-10T21:30`) — and they close
together at the shared bound:

| evaluated at | eligible |
| --- | --- |
| now | **true**, no unmet conditions |
| `2026-09-10T21:29:59-05:00` | **true** |
| `2026-09-10T21:30:01-05:00` | false — `advertisement-not-fresh`, `admission-window-expired` |

The superseded predecessor stays ineligible: `CINST-000003` at now reports
`advertisement-not-fresh`, `admission-window-expired`.

## 3. CROUTE-0004 — the candidate

```
CROUTE_ID             CROUTE-0004        (from the live sequence authority)
CROUTE_SUPERSEDES     CROUTE-0003
CROUTE_CANDIDATE      CINST-000004       exactly one; CINST-000003 is not carried
ROUTE_VERSION         4                  head is 3; the engine requires strictly greater
RECORDED_AT           2026-09-07T21:15:00-05:00
CROUTE_FROZEN_SHA256  bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda
CROUTE_FROZEN_BYTES   678
CROUTE_REQUEST_DIGEST sha256:7ff2065fff1a191a9be8d92ead5f06634bd4aaf22dee0e4de64bdce0dfa69103
```

Request class preserved exactly: `capability_id CAPDEF-0001`, `contract_id
CCON-0001`, `accepted_contract_versions [1.0.0]`, `locality local-only`,
`data_classification internal`. **No overlap window** — no carry-both cutover.

```json
{
  "request_id": "g11bbv-create-route-capdef-0001-ccon-0001-cinst-000004-supersedes-croute-0003",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-07T21:15:00-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000004"
  ],
  "data_classification": "internal",
  "route_version": 4,
  "supersedes": "CROUTE-0003",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-07"
  }
}
```

*Verbatim: extracted from this report and hashed it is `bfb15383…` at 678 bytes,
and so is the heredoc in §6. The layout is load-bearing.*

## 4. Why the route engine accepts CINST-000004

Each clause below is the released check in `create_route`, evaluated against the
production store:

| requirement | evidence |
| --- | --- |
| candidate resolves, and its capability and contract match the route's | `CAPDEF-0001` / `CCON-0001` on both |
| candidate is **its own binding root** | `_binding_root(CINST-000004) = CINST-000004` (§1.2) — `REASON_NOT_BINDING_ROOT` does not fire |
| candidate is **admitted** | `lifecycle_state: admitted` |
| candidate is **fresh** and **eligible** | §2 — 12/12, both windows open |
| contract satisfied | `satisfied_contract_versions [1.0.0]` on package, advertisement and instance |
| locality / classification match | route `local-only` / `internal`; instance scope permits `internal`, target `HOST-0001` |
| predecessor is still the head | `CROUTE-0003` superseded by nothing (§1.2) |
| version strictly greater | 4 > 3 |

The fixture write confirms the result: exactly one route head `CROUTE-0004`,
`route_version 4`, `supersedes CROUTE-0003`, `candidate_instances
[CINST-000004]`, and the request digest `sha256:7ff2065f…` — **identical to the
live preflight**.

## 5. Negative battery

Rows marked *(prod)* are read-only preflights against the production store;
rows marked *(fx)* need a store state production does not have and run against
throwaway copies. Production Fabric was byte-identical before and after
(`d550aa7e…` → `d550aa7e…`) and every row reports `mutated=false`.

| # | input | `would_accept` | reason |
| --- | --- | --- | --- |
| — | **the reviewed candidate** *(prod)* | **true** | control, `predicted_record_id=CROUTE-0004` |
| R1 | supersedes the already-superseded `CROUTE-0002` | false | `supersedes-already-superseded` |
| R1b | supersedes the oldest `CROUTE-0001` | false | `supersedes-already-superseded` |
| R1c | supersedes a `CROUTE` that does not exist | false | `unresolved-reference` |
| **R2** | **no `supersedes`: a second head for the same class** | false | `request-class-already-routed` |
| R3 | wrong capability `CAPDEF-0002` | false | `unresolved-reference` |
| R4 | wrong contract `CCON-0002` | false | `unresolved-reference` |
| R6 | wrong locality `remote` | false | `unknown-locality` |
| R7 | wrong classification `restricted` | false | `unknown-data-classification` |
| R9 | unknown candidate `CINST-000009` | false | `unresolved-reference` |
| R11 | `route_version` 3 — not greater than the head | false | `invalid-route-version` |
| R11b | `route_version` 2 | false | `invalid-route-version` |
| R12 | overlap window with no coexistence | false | `overlap-window-without-coexistence` |
| **R14** | candidate is a **withdrawal record**, not a binding root *(fx)* | false | `candidate-not-a-binding-root` |
| R15 | the reviewed body replayed once `CROUTE-0004` is spent *(fx)* | false | `supersedes-already-superseded`, predicts `CROUTE-0005` |

A double-run is safe.

### 5.1 Four cases the engine does NOT refuse — measured, not assumed

The authorisation expected refusals here. **It does not get them**, and saying so
matters more than a tidy table. Every one is fail-closed *downstream* instead,
and the reviewed candidate exercises none of them.

| # | input | verdict | what actually gates it |
| --- | --- | --- | --- |
| **R8** | candidate is the **superseded** `CINST-000003` | **accepted** | eligibility at use: `advertisement-not-fresh`, `admission-window-expired` |
| **R8b** | candidate is the oldest `CINST-000001` | **accepted** | same |
| **R10** | carries **both** `CINST-000003` and `CINST-000004` | **accepted** | the stale candidate is ineligible at use |
| **R13** | candidate is a binding that has since been **withdrawn** *(fx)* | **accepted** | eligibility at use: `instance-not-admitted` |
| **R5** | `accepted_contract_versions: [2.0.0]`, which no record declares | **accepted** | eligibility at use: `contract-version-not-accepted`, `package-version-not-accepted` |

**R13 is the subtle one.** `create_route` checks `lifecycle_state != "admitted"`
on the *named* record — but a withdrawal does not mutate the binding. It writes a
**new successor record** (`CINST-000005`, `lifecycle_state: withdrawn`,
`reason_category: withdrawal`) whose binding root is `CINST-000004`, and
`CINST-000004` itself stays `admitted` forever. So the not-admitted check cannot
fire on a binding root, and naming the withdrawal record instead is refused
earlier by `candidate-not-a-binding-root` (R14). The check exists; the state that
would trigger it is unreachable by that path.

**R5 produces a route nobody can use.** Written, it stores
`accepted_contract_versions: [2.0.0]` while `CPKG-0001` declares `[1.0.0]`, and
eligibility through that class then refuses. The identity is spent on an
un-routable route — wasteful, not unsafe.

**Confirmed architecture fact:** *a route may still name a superseded instance in
general.* R8, R8b and R10 are that fact, executed. **The reviewed candidate does
not exercise it** — `candidate_instances` is exactly `[CINST-000004]`, the
current head, its own binding root, admitted, fresh and eligible — and step L of
the ceremony reads `candidate_instances` back from the written record because the
engine will not do it.

## 6. The operator freeze block

**It writes exactly one path, `/etc/kyri/fabric/croute-0004.json`, and performs
no Fabric write.** The only command it runs against `/var/lib/kyri/fabric` is a
`--preflight` and a read-only aggregate. `root:cschott 0640` matches all
eighteen accepted inputs already there.

Verified before publication: the heredoc was extracted from this report and
hashed — `bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda` at
678 bytes, byte-identical to the rehearsed candidate. Each refusal arm was
exercised against a real body.

```bash
bash <<'FREEZE_CROUTE'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/croute-0004.json
REVIEWED=bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda
REVIEWED_BYTES=678

# Bodies that are NOT this one, refused BY NAME. The G11-BB-S §11 candidate is
# well formed and the engine would take it -- same class, same predecessor,
# same candidate -- but it carries that checkpoint's request_id and timestamp.
SUPERSEDED_BBS=12987fb0b22ed124257c135e2be0e114b12f4ec870d53c7ec3991e7d4c0b74fc
ACCEPTED_CROUTE3=724ec6c2c71330e713b7df691dc025a3a4253cf3e6aef756debd301ab0d29976

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

sudo test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

# The binding this route names must be the one that was reviewed and written.
sudo test -e /etc/kyri/fabric/cinst-000004.json || {
  echo "REFUSE: the CINST-000004 input is absent; this route has no reviewed candidate"
  exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11bbv-create-route-capdef-0001-ccon-0001-cinst-000004-supersedes-croute-0003",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-07T21:15:00-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000004"
  ],
  "data_classification": "internal",
  "route_version": 4,
  "supersedes": "CROUTE-0003",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-07"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
case "${ACTUAL}" in
  "${SUPERSEDED_BBS}")
    echo "REFUSE: this is the SUPERSEDED G11-BB-S §11 candidate, not the reviewed G11-BB-V one"
    rm -f "${TMP}"; exit 1 ;;
  "${ACCEPTED_CROUTE3}")
    echo "REFUSE: this is the already-accepted CROUTE-0003 input"
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
cd /opt/schott-platform
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file croute-0004.json --approved-directory /etc/kyri/fabric --preflight

printf '\n--- production Fabric must be byte-identical to before ---\n'
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
echo "expect d550aa7ef70e30854c2291429b7174a7f4f1467501437390f7d24e1f45c50ff8  -"
FREEZE_CROUTE
```

### 6.1 Expected output

```
/etc/kyri/fabric BEFORE   18 entries, newest cinst-000004.json
frozen input              bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda
                          /etc/kyri/fabric/croute-0004.json  root:cschott  640  678 bytes
/etc/kyri/fabric AFTER    19 entries; croute-0004.json is the only addition
preflight                 would_accept true, mutated false,
                          predicted_record_id CROUTE-0004, destination_exists false,
                          request_digest sha256:7ff2065fff1a191a9be8d92ead5f06634bd4aaf22dee0e4de64bdce0dfa69103
fabric aggregate          d550aa7ef70e30854c2291429b7174a7f4f1467501437390f7d24e1f45c50ff8
```

**Read `would_accept`, not `outcome`.** The `create-route` write is not in this
block and is not authorised by this checkpoint.

## 7. Selection — derived only

```
NEXT_CSEL = CSEL-000003     from the live sequence authority
PREMATURE_SELECTION_AUTHORISED = NO
```

Its exact candidate is **not** built here. A selection input carries no
`route_id`; it names a request class and the route is resolved at selection
time, so preparing it now would review bytes that mean something different once
`CROUTE-0004` exists. G11-BB-S §11.4 measured the cost: a premature selection is
*accepted*, spends `CSEL-000003`, binds the stale head and stores
`selected_instance_id: null`, with the same request digest as the correct one.
`CSEL-000003` preparation is authorised only after `CROUTE-0004` is written and
independently verified.

## 8. Invocation safety

No invocation-related mutation. Read-only:

```
CINV-000001 sha256      1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
CINV-000001 outcome     execution-prepared   adapter_identity null   -> permanently UNRESOLVED
CINV-000001 resume      FORBIDDEN
CINV seq 1              CRES count 0
next CINV-000002 unspent    next CRES-000001
validate_store          findings ()
```

## 9. Follow-ups carried forward

None blocks `CROUTE-0004`.

- **New, measured this checkpoint:** `create_route` does not check candidate
  *liveness* — superseded, expired, and withdrawn-binding candidates are all
  accepted at write (§5.1). Each is fail-closed at use by eligibility, so the
  exposure is a spent identity and an unusable route rather than an unsafe one.
- **New:** `create_route` does not validate `accepted_contract_versions` against
  what the contract and package declare (R5).
- A route may name a superseded instance — confirmed again, and designed around.
- Scope intersection silently narrows rather than refusing (G11-BB-U §6.1).
- The selection request digest does not witness the resolved route.
- The request digest does not cover `request_id` (G11-BB-T §3.2).
- There is no maximum validity-window policy (G11-BB-T §2.1).

## 10. Validation

No source, test or provisioning file changed; this checkpoint adds this report
only.

```
FOCUSED FABRIC SUITES   15 suites, 9589 assertions, 0 FAIL
LOCAL_QUICK             PASS
LOCAL_FULL              PASS
GITHUB CI               6/6
CLEAN CLONE             PASS

production Fabric across CINST verification and CROUTE preparation
  d550aa7ef70e30854c2291429b7174a7f4f1467501437390f7d24e1f45c50ff8   byte-identical
production Trust
  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   byte-identical
capability-route.seq  3      capability-routes  CROUTE-0001..3
```

## 11. Next

```
PRODUCTION_CROUTE_WRITE       NOT_PERFORMED
CINV_NEXT                     CINV-000002    unspent
CRES_COUNT                    0
PRODUCTION_INVOKE_AUTHORISED  NO
```

Reviewer accepts this acceptance and preparation; the operator then runs the §6
freeze block and returns its output. The `create-route` write is a separate
authorised step.
