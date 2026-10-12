# ENG-0005 G11-BB-U — CADV-000005 acceptance, and CINST-000004 preparation

**Status: the `CADV-000005` write is independently verified and accepted. The
Fabric delta is exactly one CREATE and one REPLACE, proved by content
reconstruction rather than by counting files. `CINST-000004` is prepared,
digest-pinned and rehearsed read-only — and NOT written.**

```
CADV_HEAD                       CADV-000005   sole head by supersession
FABRIC_DELTA                    1 CREATE, 1 REPLACE, 0 REMOVE   (reconstructed)
CADV_000004_UNCHANGED           YES
CINST_PREFLIGHT                 PASS
BINDING_ROOT                    CINST-000004  (its own — see §5)
PRODUCTION_CINST_WRITE          NOT_PERFORMED
FABRIC_MUTATION_FROM_PREPARATION NONE
PREMATURE_SELECTION_AUTHORISED  NO
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. The CADV-000005 write, verified independently

The stored record, read from production:

```
advertisement_id        CADV-000005
capability_host_id      CHOST-0001
capability_package_id   CPKG-0001
contract_id             CCON-0001
supersedes              CADV-000004
advertised_resource_profile.architecture   x86-64
satisfied_contract_versions                [1.0.0]
observed_at             2026-09-06T21:30:00-05:00
valid_until             2026-09-10T21:30:00-05:00
evidence.reason_category                   supersession
evidence.approving_authority               null
evidence.causal_references                 [CHOST-0001, CPKG-0001, CCON-0001, CADV-000004]
evidence.request_id     g11bbt-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000004
evidence.request_digest sha256:83cd12eb1418935e2fdfedaaf9fbbfa19107bd76b996630333d01fe91710f95a

CADV_STORED_SHA256      3c9eca9f9ac0a51f164106f5c01ea78cd513b4f457ff3dedc4070ffd97c256aa
```

Every reviewed field matches G11-BB-T §2, and **the stored request digest is the
digest the reviewer approved** — the same value the live preflight and the
fixture write both produced before the freeze. The frozen input is still on disk
at the reviewed bytes:

```
/etc/kyri/fabric/cadv-000005.json  root:cschott  640  673 bytes
ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad
```

### 1.1 The delta, by content reconstruction

File counts and sizes cannot show that an unrelated record was rewritten in
place, so the delta is proved the other way round: take the **current** per-path
digest manifest, drop exactly `CADV-000005.yaml`, set the advertisement sequence
back to its pre-write bytes, and re-aggregate. If that reproduces the
operator-reported pre-write aggregate, then those two paths are the *only*
things that changed — every other path is byte-identical by construction.

```
CREATE   /var/lib/kyri/fabric/capability-advertisements/CADV-000005.yaml
REPLACE  /var/lib/kyri/fabric/sequences/capability-advertisement.seq
           before  7de1555df0c2700329e815b93b32c571c3ea54dc967b89e81ab73b9972b72d1d   b"4\n"
           after   f0b5c2c2211c8d67ed15e75e656c7862d086e9245420892a7de62cd9ec582a06   b"5\n"
REMOVE   none

reconstructed pre-write aggregate  7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
operator-reported pre-write        7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   MATCH

post-write aggregate               54dcce685e481302c20de2a7716594aef43fc4c498e9d275ce53305a333951cd
```

Corroborated by modification times — exactly three paths carry the write
instant, and nothing in the store is newer:

```
2026-09-07 13:44:17.746  sequences/capability-advertisement.seq
2026-09-07 13:44:17.752  capability-advertisements/CADV-000005.yaml
2026-09-07 13:44:17.753  capability-advertisements/            (directory entry)
```

```
CADV-000004  965499a3dace61d620b3d6a00bbc59a0655bceaeedcdd0ca879e8245574af708
             mtime 2026-09-02 13:44:40   UNCHANGED
trust aggregate  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   UNCHANGED

fabric validate  valid, findings []
  CADV 5   CINST 3   CROUTE 3   CSEL 2   CAPDEF 1   CCON 1   CPKG 1   CHOST 1
trust  validate  valid, problems []
```

Instance, route and selection sequences are untouched at 3, 3 and 2.

## 2. Head derivation

By supersession graph, not by sequence number:

```
CADV-000001 supersedes None
CADV-000002 supersedes CADV-000001
CADV-000003 supersedes CADV-000002
CADV-000004 supersedes CADV-000003
CADV-000005 supersedes CADV-000004

heads (superseded by nothing) = [CADV-000005]      exactly one
CADV_SEQ = 5     next = CADV-000006
```

## 3. Current eligibility

Trust standing at now, through the released evaluator, for the request class
`CAPDEF-0001 / execute / internal / HOST-0001`:

```
CPKG-0001   usable   HOST-0001   usable
```

The advertisement is fresh: `2026-09-06T21:30:00-05:00 <= now < 2026-09-10T21:30:00-05:00`.

**Instance eligibility is NOT claimed, and the production instance is still not
eligible.** `CINST-000003` names the superseded `CADV-000004` and its own
admission window closed. Evaluated at now:

```
ELIG-1..5  met     ELIG-8..12  met
ELIG-6     unmet   advertisement-not-fresh
ELIG-7     unmet   admission-window-expired
eligible   false
```

Ten of twelve conditions hold — Trust usable in both domains, contract
satisfied, resource profile satisfying, scope permitting, nothing quarantined or
drained. The two that do not are precisely the two `CINST-000004` exists to
close, and they cannot close until it is written.

## 4. CINST-000004 — the candidate

```
CINST_ID             CINST-000004        (from the live sequence authority)
CINST_SUPERSEDES     CINST-000003
ADVERTISEMENT_ID     CADV-000005
RECORDED_AT          2026-09-07T14:15:00-05:00
EVALUATED_AT         2026-09-07T14:15:00-05:00
ADMITTED_AT          2026-09-07T14:15:00-05:00
ADMITTED_UNTIL       2026-09-10T21:30:00-05:00     equal to CADV-000005.valid_until
BINDING_ROOT         CINST-000004                  its own — see §5
CINST_FROZEN_SHA256  5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c
CINST_FROZEN_BYTES   1269
CINST_REQUEST_DIGEST sha256:cde47b441c4cd9d7f3e40cc554e203cd0d3e1a06e62ae799e901db30a23c4b77
```

```json
{
  "request_id": "g11bbu-admit-instance-cpkg-0001-chost-0001-cadv-000005-supersedes-cinst-000003",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-07T14:15:00-05:00",
  "evaluated_at": "2026-09-07T14:15:00-05:00",
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
  "admission_decision_id": "eng-0005-cinst-000004-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000005",
  "supersedes": "CINST-000003",
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
  "admitted_at": "2026-09-07T14:15:00-05:00",
  "admitted_until": "2026-09-10T21:30:00-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-07"
  }
}
```

*Verbatim: extracted from this report and hashed it is `5d268f70…` at 1269
bytes, and so is the heredoc in §7. The layout is load-bearing.*

**The window.** `admit_instance` enforces four bounds (`admission.py` §6), and
this candidate sits inside all four:

| bound | this candidate |
| --- | --- |
| `observed_at <= evaluated_at < valid_until` | `09-06 21:30 <= 09-07 14:15 < 09-10 21:30` |
| `observed_at <= admitted_at` | holds |
| `evaluated_at < admitted_until` | holds |
| `admitted_until <= valid_until` | **equal** — the accepted case, see M4c |

Equality is deliberate and is the released reading: both windows are half-open
on the right, so an admission ending exactly where the claim ends creates no
overhang. Nothing in Trust required a narrower window — both subjects are usable
across it — so the advertisement bound is taken in full.

**`evaluated_at` is the instant Trust is judged at.** Freezing it freezes the
Trust evaluation instant too, which is the released design; the reviewed body
therefore does not decay, but the operator should run the write while
`evaluated_at` still sits inside the advertisement window.

## 5. Binding root — derived, not assumed

`_binding_root` (`tools/fabric/admission.py:760`) walks a supersession chain
only while the record's own `evidence.reason_category` is a **lifecycle**
category:

```
LIFECYCLE_CATEGORIES = ('withdrawal', 'retirement')
```

`admit_instance` files a supersession as `reason_category="supersession"`, which
is not in that set, so the walk stops at the record itself. Run against the
fixture-written chain:

```
CINST-000001  reason_category=instance-admission  supersedes=None          binding_root=CINST-000001
CINST-000002  reason_category=supersession        supersedes=CINST-000001  binding_root=CINST-000002
CINST-000003  reason_category=supersession        supersedes=CINST-000002  binding_root=CINST-000003
CINST-000004  reason_category=supersession        supersedes=CINST-000003  binding_root=CINST-000004
```

```
BINDING_ROOT = CINST-000004
```

**`CINST-000004` is its own binding root, not a continuation of `CINST-000003`.**
Ordinary declared supersession is not a lifecycle category — the ruling G11-N
and G11-P settled — and this is re-derived here through released source rather
than carried forward as an assumption. It has a direct consequence for the next
stage: `create-route` requires every candidate to be its own binding root
(`admission.py:1936`, `REASON_NOT_BINDING_ROOT`), so `CROUTE-0004` must name
`CINST-000004` and a route still naming `CINST-000003` would bind a different
binding.

## 6. Negative battery

Every row is a **read-only preflight against the production store**. Production
Fabric was byte-identical before and after the whole battery
(`54dcce68…` → `54dcce68…`) and every row reports `mutated=false`.

| # | input | `would_accept` | reason |
| --- | --- | --- | --- |
| — | **the reviewed candidate** | **true** | control, `predicted_record_id=CINST-000004` |
| M1 | supersedes the already-superseded `CINST-000002` | false | `supersedes-already-superseded` |
| M1b | supersedes the oldest `CINST-000001` | false | `supersedes-already-superseded` |
| M1c | supersedes a `CINST` that does not exist | false | `unresolved-reference` |
| M2 | names the superseded `CADV-000004` | false | `advertisement-record-superseded` |
| M2b | names the older `CADV-000003` | false | `advertisement-record-superseded` |
| M2c | names an advertisement that does not exist | false | `unresolved-reference` |
| M3 | evaluated after the advertisement expires | false | `advertisement-not-fresh` |
| M4 | `admitted_until` **one second** past `valid_until` | false | `admission-window-exceeds-advertisement` |
| M4b | `admitted_until` 24 h past `valid_until` | false | `admission-window-exceeds-advertisement` |
| M4c | `admitted_until` **equal** to `valid_until` | **true** | the reviewed case; no overhang |
| M5 | wrong capability `CAPDEF-0002` | false | `unresolved-reference` |
| M6 | wrong host `CHOST-0002` | false | `unresolved-reference` |
| M7 | wrong package `CPKG-0002` | false | `unresolved-reference` |
| M8 | resource profile is a string, not a mapping | false | `malformed-operation-content` |
| M8b | profile claims more than `CHOST-0001` verifies | false | `resource-dimension-not-governed` |
| M9 | Trust record that does not exist | false | `trust-unavailable` |
| M9b | package Trust record is the host's | false | `trust-subject-type-mismatch` |
| M12a | Trust store empty | false | `trust-unavailable` |
| M12b | host Trust record removed | false | `trust-unavailable` |
| M12c | host Trust record corrupted | false | `trust-unavailable` |

Refused at one second past the advertisement bound. There is no tail.

**M11 — duplicate next identity.** The reviewed body was written into a
throwaway copy of the live store, returning `outcome=accepted`,
`record_id=CINST-000004` and request digest `sha256:cde47b44…` — **identical to
the live preflight**. Replayed against that store:

| # | input | `would_accept` | reason | predicted |
| --- | --- | --- | --- | --- |
| M11 | the same body once `CINST-000004` is spent | false | `supersedes-already-superseded` | `CINST-000005` |

A double-run is safe.

### 6.1 M10 — scope escalation: measured, not assumed

The engine does **not** refuse a widened `admission_scope`. It accepts the
request and stores the **intersection**. Measured on throwaway copies:

| requested | verdict | stored `effective_scope` |
| --- | --- | --- |
| `permitted_operations: [execute, administer]` | **accepted** | `[execute]` — silently narrowed |
| `permitted_targets: [HOST-0001, HOST-0002]` | **accepted** | `[HOST-0001]` — silently narrowed |
| `permitted_capabilities: [CAPDEF-0001, CAPDEF-0002]` | **accepted** | `[CAPDEF-0001]` — silently narrowed |
| `permitted_data_classifications: [internal, restricted]` | **refused** | `unknown-data-classification` |

```
SCOPE_INTERSECTION_ESCALATION        NO    nothing extra reaches the stored scope
SCOPE_INTERSECTION_SILENT_NARROWING  YES   in capabilities, operations and targets
FOLLOW_UP_REQUIRED                   YES
```

There is no privilege escalation: the excess never lands. What is missing is a
refusal — an operator who asks for more than Trust grants is told nothing, and
only the stored record shows what they actually got. Data classification is the
one dimension validated against a governed vocabulary instead.

**It does not block the reviewed candidate**, and is carried forward rather than
fixed here. Proved directly: written into a throwaway copy, the reviewed body's
requested scope and its stored `effective_scope` are **equal in all four
dimensions** — it does not exercise the narrowing at all.

```
permitted_capabilities          [CAPDEF-0001]
permitted_operations            [execute]
permitted_data_classifications  [internal]
permitted_targets               [HOST-0001]
lifecycle_state                 admitted
```

### 6.2 What the fresh chain would close — fixture only

Not a production claim; `CINST-000004` does not exist in production. Against the
throwaway copy that has it:

| evaluated at | eligible |
| --- | --- |
| `2026-09-07T14:20:00-05:00` | **true**, no unmet conditions |
| `2026-09-10T21:29:59-05:00` | **true** |
| `2026-09-10T21:30:01-05:00` | false — `advertisement-not-fresh`, `admission-window-expired` |

ELIG-6 and ELIG-7, the two open in §3, both close and both re-close together at
the shared bound.

## 7. The operator freeze block

**It writes exactly one path, `/etc/kyri/fabric/cinst-000004.json`, and performs
no Fabric write.** The only command it runs against `/var/lib/kyri/fabric` is a
`--preflight` and a read-only aggregate. `root:cschott 0640` matches all
seventeen accepted inputs already in that directory.

Verified before publication: the heredoc was extracted from this report and
hashed, and it renders `5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c`
at 1269 bytes — byte-identical to the rehearsed candidate. Each refusal arm was
exercised against a real body.

```bash
bash <<'FREEZE_CINST'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cinst-000004.json
REVIEWED=5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c
REVIEWED_BYTES=1269

# Bodies that are NOT this one, refused BY NAME. The G11-BB-S §11 candidate is
# well formed and the engine would take it -- it names CADV-000005 and
# supersedes CINST-000003 -- but it carries that checkpoint's timestamps and
# admitted_until, which no longer match the written advertisement.
SUPERSEDED_BBS=6ac02e0c14451e544dec255e2dfaf06f5c44687fd6cf41bf571d76742eb96215
ACCEPTED_CINST3=1e96983e7a32bd2658f1aa75183a4a8ac008d0feac898887443151472a793085

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

sudo test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

# The advertisement this admission binds to must be the one that was reviewed.
sudo test -e /etc/kyri/fabric/cadv-000005.json || {
  echo "REFUSE: the CADV-000005 input is absent; this admission has no reviewed predecessor"
  exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11bbu-admit-instance-cpkg-0001-chost-0001-cadv-000005-supersedes-cinst-000003",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-07T14:15:00-05:00",
  "evaluated_at": "2026-09-07T14:15:00-05:00",
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
  "admission_decision_id": "eng-0005-cinst-000004-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000005",
  "supersedes": "CINST-000003",
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
  "admitted_at": "2026-09-07T14:15:00-05:00",
  "admitted_until": "2026-09-10T21:30:00-05:00",
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
    echo "REFUSE: this is the SUPERSEDED G11-BB-S §11 candidate, not the reviewed G11-BB-U one"
    rm -f "${TMP}"; exit 1 ;;
  "${ACCEPTED_CINST3}")
    echo "REFUSE: this is the already-accepted CINST-000003 input"
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
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file cinst-000004.json --approved-directory /etc/kyri/fabric --preflight

printf '\n--- production Fabric must be byte-identical to before ---\n'
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
echo "expect 54dcce685e481302c20de2a7716594aef43fc4c498e9d275ce53305a333951cd  -"
FREEZE_CINST
```

### 7.1 Expected output

```
/etc/kyri/fabric BEFORE   17 entries, newest cadv-000005.json
frozen input              5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c
                          /etc/kyri/fabric/cinst-000004.json  root:cschott  640  1269 bytes
/etc/kyri/fabric AFTER    18 entries; cinst-000004.json is the only addition
preflight                 would_accept true, mutated false,
                          predicted_record_id CINST-000004, destination_exists false,
                          request_digest sha256:cde47b441c4cd9d7f3e40cc554e203cd0d3e1a06e62ae799e901db30a23c4b77
fabric aggregate          54dcce685e481302c20de2a7716594aef43fc4c498e9d275ce53305a333951cd
```

**Read `would_accept`, not `outcome`.** The `admit-instance` write is not in
this block and is not authorised by this checkpoint.

## 8. Route and selection — derived only

```
NEXT_CROUTE  CROUTE-0004   supersedes CROUTE-0003, route_version 4,
                           candidate_instances [CINST-000004]   (§5: its own binding root)
NEXT_CSEL    CSEL-000003   request class only; resolves against CROUTE-0004

PREMATURE_SELECTION_AUTHORISED = NO
```

Neither is prepared, frozen or preflighted here. `CROUTE-0004` may be prepared
only after `CINST-000004` is written and accepted; `CSEL-000003` only after
`CROUTE-0004` is written and accepted. A selection input carries no `route_id`
and resolves the route at selection time, so preparing it early would bind the
stale head — G11-BB-S §11.4 measured that a premature selection is *accepted*,
spends the identity and stores `selected_instance_id: null`.

## 9. Follow-ups carried forward

None blocks `CINST-000004`.

- Scope intersection silently narrows rather than refusing an unsupported
  requested scope (§6.1) — measured this checkpoint across three dimensions.
- A route may name a **superseded** instance and the engine accepts it; §5 gives
  the binding-root reason this matters for `CROUTE-0004`.
- The selection request digest does not witness the resolved route.
- The request digest does not cover `request_id` (G11-BB-T §3.2), so it is not a
  witness for the frozen file — hence the file digest and byte-count pins.
- There is no maximum validity-window policy (G11-BB-T §2.1).

## 10. Validation

No source, test or provisioning file changed; this checkpoint adds this report
only. Counts are fresh.

```
FOCUSED FABRIC SUITES   15 suites, 9589 assertions, 0 FAIL
LOCAL_QUICK             PASS
LOCAL_FULL              PASS
GITHUB CI               6/6
CLEAN CLONE             PASS

production Fabric across CADV verification and CINST preparation
  54dcce685e481302c20de2a7716594aef43fc4c498e9d275ce53305a333951cd   byte-identical
production Trust
  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   byte-identical
capability-instance.seq  3      capability-instances  CINST-000001..3
```

## 11. Next

```
PRODUCTION_CINST_WRITE        NOT_PERFORMED
CINV_NEXT                     CINV-000002    unspent
CRES_COUNT                    0
PRODUCTION_INVOKE_AUTHORISED  NO
```

Reviewer accepts this acceptance and preparation; the operator then runs the §7
freeze block and returns its output. The `admit-instance` write is a separate
authorised step.
