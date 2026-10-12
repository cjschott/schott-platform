# ENG-0005 G11-AY-D — CINST-000003 production write, accepted

**Status: accepted.** `CINST-000003` is written to production and independently
verified from the stored record, not from the CLI's report of itself.

Follows **[G11-AY-C](2026-09-02-g11-ay-c-cinst-000003-preparation.md)**, which
prepared the candidate, and **[G11-AY-B](2026-09-02-g11-ay-b-cadv-000004-production-write.md)**,
which accepted the `CADV-000004` advertisement this instance binds to.

Branch `arch/eng-0005-execution-transition`, HEAD `8a2c7dc` at the write.

---

## 1. The frozen input

Verified at `/etc/kyri/fabric/cinst-000003.json` **after** the write, so the
input the ceremony reviewed is the input that survived it:

```
root:cschott  0640  1268 bytes
1e96983e7a32bd2658f1aa75183a4a8ac008d0feac898887443151472a793085
```

That is the AY-C §7/§8 candidate exactly. Before the operator froze it, the §8
`BODY` block was rendered independently and confirmed to produce **1268 bytes**
at the same digest, byte-identical to the §7 reviewed candidate — so the block
the operator ran and the body the reviewer read were proven to be one thing
before any privileged install.

## 2. Production CLI output

```
python3 -m tools.fabric.cli admit-instance \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file cinst-000003.json --approved-directory /etc/kyri/fabric
```

```json
{
  "outcome": "accepted",
  "reason": null,
  "record_id": "CINST-000003",
  "record_kind": "capability-instance",
  "request_digest": "sha256:9ab832ff8afc9aa24c9030904ea91596bea96e58f9747fff596374c820779b24",
  "request_id": "g11ay-admit-instance-cpkg-0001-chost-0001-cadv-000004-supersedes-cinst-000002"
}
```

**This output is not the evidence.** Everything below was read back off disk.

The request digest `sha256:9ab832ff…0779b24` is now carried by **five**
independent runs at one value: the AY-C fixture preflight, the AY-C fixture
write, the AY-C live preflight, an independent read-only preflight run during
this session's reconstruction, and the accepted write. The stored record carries
it too — §3.

## 3. The record, read from production

`/var/lib/kyri/fabric/capability-instances/CINST-000003.yaml` —
`cschott:cschott 0600`, **1407 bytes**, stored digest
`5b83135db80693e430d92f36a04fea837b354949a2a4bee18170da73f70c21d1`.

| governed field | required | stored | |
| --- | --- | --- | --- |
| `instance_id` | `CINST-000003` | `CINST-000003` | ✓ |
| `supersedes` | `CINST-000002` | `CINST-000002` | ✓ |
| `advertisement_id` | `CADV-000004` | `CADV-000004` | ✓ |
| `capability_id` | `CAPDEF-0001` | `CAPDEF-0001` | ✓ |
| `capability_package_id` | `CPKG-0001` | `CPKG-0001` | ✓ |
| `capability_host_id` | `CHOST-0001` | `CHOST-0001` | ✓ |
| `contract_id` | `CCON-0001` | `CCON-0001` | ✓ |
| `satisfied_contract_versions` | `["1.0.0"]` | `['1.0.0']` | ✓ |
| `verified_resource_profile` | `architecture=x86-64` | `{'architecture': 'x86-64'}` | ✓ |
| `package_trust_record_id` | `TREC-000002` | `TREC-000002` | ✓ |
| `host_trust_record_id` | `TREC-000001` | `TREC-000001` | ✓ |
| `admitted_until` | read from disk | **`2026-09-06T12:02:14-05:00`** | ✓ |
| `lifecycle_state` | — | `admitted` | ✓ |

`reason_category: supersession`. `causal_references: [CAPDEF-0001, CCON-0001,
CPKG-0001, CHOST-0001, CADV-000004, CINST-000002]`.
`trust_evidence_references: [TREC-000002, TREC-000001]`.

**Effective scope, as stored:**

```
permitted_capabilities         [CAPDEF-0001]
permitted_operations           [execute]
permitted_data_classifications [internal]
permitted_targets              [HOST-0001]
```

Requested and granted are identical — AY-C §5 noted that the effective scope is
an intersection and that asking for more than standing permits narrows
**silently**. This candidate requested exactly what both standings carry, so
that edge is not exercised here. It remains open as follow-up hardening and was
deliberately not changed by this checkpoint.

## 4. Sequence

```
capability-instance.seq   2  ->  3
```

Advertisement, route and selection sequences unmoved at **4 / 2 / 1**.

**Both representations are 2 bytes** (`2\n` → `3\n`). A structural manifest
comparing paths, owners, modes and sizes reports this file as *unchanged*. Only
content accounting sees it, which is why §7 does content accounting.

## 5. Head

Derived two independent ways, not assumed.

**Raw set difference** — all instance IDs minus every `supersedes` target:

```
all        : CINST-000001, CINST-000002, CINST-000003
superseded : CINST-000001, CINST-000002
heads      : CINST-000003          (exactly one)
```

**`CINST_HEAD = CINST-000003`.** No fork, no ambiguity.

## 6. Predecessor non-mutation

`CINST-000002` after the write:

```
5cfcf01e778856889c6aaa0838f986a0c43878033b29da1fd198be3070e3f719
```

The **same** digest recorded for it in
[G11-T](2026-08-28-g11-t-croute-0002-production-write.md) and again in
[G11-Z2](2026-08-29-g11-z2-generation-12-production-install.md) — durable
baselines written days before this ceremony existed, so the comparison is
against independent history rather than against a value this ceremony produced.

**Byte-identical. Supersession did not touch the predecessor.** The relationship
lives in the *successor's* `supersedes` field, which is the append-only model
ADR-0012 states: *"Superseded records remain readable. Nothing is edited."*

`CINST-000001` likewise unchanged at
`92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729`.

## 7. Binding root

Re-run against the **live stored records** through the released
`tools.fabric.admission._binding_root`, not inferred from AY-C:

```
LIFECYCLE_CATEGORIES = ('withdrawal', 'retirement')

CINST-000001  reason_category=instance-admission  supersedes=None
CINST-000002  reason_category=supersession        supersedes=CINST-000001
CINST-000003  reason_category=supersession        supersedes=CINST-000002

binding root of CINST-000001 : CINST-000001
binding root of CINST-000002 : CINST-000002
binding root of CINST-000003 : CINST-000003
```

**`BINDING_ROOT = CINST-000003`.**

The walk continues backward only while a record's `reason_category` is a
lifecycle category. `supersession` is **not** one, so the walk stops at the
record itself. Stated again because it governs what comes next: *a lifecycle
decision continues a binding; a declared supersession starts a new one.*
`CINST-000003` is a **new binding**, not a transparent continuation of
`CINST-000002`, and nothing downstream — route, selection or invoke — may treat
it as one.

## 8. Dependency bound

Both values read from the live stored records. Nothing recomputed:

```
CADV-000004.valid_until      '2026-09-06T12:02:14-05:00'
CINST-000003.admitted_until  '2026-09-06T12:02:14-05:00'

admitted_until <= valid_until   True
tail                            0.0 seconds
```

**Equality** — the strongest position the G11-AG bound permits.
`DEPENDENCY_BOUNDED = YES`, `R17_TAIL = ZERO`. The admission cannot outlive its
advertisement by even one second.

AY-C proved the bound refuses at `valid_until + 1 second` and at `+1 hour`, and
accepts at equal and shorter. That rule was not weakened to land this write.

## 9. Trust, Fabric and eligibility

```
fabric validate   status: reported   findings: []
                  counts 4 / 3 / 2 / 1  (advertisements / instances / routes / selections)

trust validate-store   valid: true   problems: []
                       counts  audit 4, authority 1, decision 2, evidence 7, lineage 3, record 2
```

`FABRIC_VALID = YES`, `FABRIC_DEFECTS = 0`, `TRUST_VALID = YES`.

**Current eligibility of `CINST-000003`**, through the released engine at a
current instant `2026-09-03T06:41:35-05:00`:

```
eligible : true
unmet    : []
ELIG-1 .. ELIG-12   all met
```

All twelve conditions met for the fresh binding. `compute-eligibility` is
read-only — **no selection and no invocation evidence was created**, confirmed
by the manifest in §7 of this section being unchanged after the evaluation.

## 10. Mutation accounting

**Structural manifest** — paths, owners, modes, sizes:

```
+ capability-instances/CINST-000003.yaml   cschott:cschott  600  1407
```

That is the *entire* structural delta. The sequence replacement is invisible to
it, because `2\n` and `3\n` are both 2 bytes.

**Content manifest** — per-file digests, which is the accounting that binds:

```
CREATE   capability-instances/CINST-000003.yaml   5b83135d…c21d1
REPLACE  sequences/capability-instance.seq        53c234e5… -> 1121cfcc…
REMOVE   (none)
unchanged  21 of 22 pre-existing files
```

**Proved by reconstruction, not by assertion.** Before the write, this session
recorded the Fabric content-manifest aggregate as
`498e24232fe3fd0adf43c2ee8f654cbf3295de47f3c7d48ef979d9bb8ebeff8c`. Taking the
post-write manifest, removing the `CINST-000003` line and reverting only the
instance sequence digest to that of `2\n` reproduces:

```
reconstructed pre-write : 498e24232fe3fd0adf43c2ee8f654cbf3295de47f3c7d48ef979d9bb8ebeff8c
recorded    pre-write   : 498e24232fe3fd0adf43c2ee8f654cbf3295de47f3c7d48ef979d9bb8ebeff8c   MATCH
```

If anything else in the store had moved by a single byte, the reconstruction
would not have landed on the recorded value. **Exactly two changes occurred, and
they are the two intended ones.** Post-write aggregate:
`f56503b280d4b86f1eb9addfcc5d98eda128e1a346ef07076c90219f1086e56d`.

Independently corroborated by modification times — the only Fabric paths touched
today are the new record, the instance sequence, and the `capability-instances`
directory entry that had to change to hold the record.

**Surfaces this write did not touch:**

| | |
| --- | --- |
| `CADV-000004` | `965499a3…4af708` unchanged |
| `CADV-000003` | `f2b48c2e…7116d` unchanged |
| `CROUTE-0002` | `1a7ed018…43870` unchanged |
| `CSEL-000001` | `e08a4df4…e79bb` unchanged |
| Trust store | no file modified today; `valid: true`, counts unmoved |
| runtime | no `/usr/lib/kyri` or `/usr/libexec` object modified today |
| helpers | `74b84015…125874`; **`compatible`**, 8 declared, 0 blocking |
| identity authorities | `3dec888c…` / `891beeeb…` unchanged |
| Root Authority | `/mnt/kyri-root` **unmounted** |

## 11. Route consequence

`CROUTE-0002`, read from production:

```
route_id            CROUTE-0002
candidate_instances [CINST-000002]        <- only
capability_id       CAPDEF-0001
contract_id         CCON-0001
accepted_contract_versions [1.0.0]
data_classification internal
locality            local-only
route_version       2
supersedes          CROUTE-0001
```

`candidate_instances` names **only `CINST-000002`**, which is now a superseded
record. `NEW_INSTANCE_ROUTABLE = NO`.

**This is expected and was not corrected here.** The route was deliberately not
modified by AY-D. A renewed instance that validates, is head, and is eligible is
still not reachable, because reachability is the route's authority and the route
has not been renewed.

## 12. Invocation authority

```
PRODUCTION_CINV_COUNT = 0
PRODUCTION_CRES_COUNT = 0
capability-invocations / capability-results directories   do not exist
handoff root entries                                      0
sudoers non-README                                        0
```

`SUDOERS_CLOSED = YES`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

Admitting an instance grants no execution authority, and this write created no
invocation record — it could not have, because `admit-instance` does not invoke
anything and no privileged grant exists for anything that would.

## 13. What this does not restore

The Fabric chain is now renewed at its advertisement **and** its instance. It is
still not renewed at its route or its selection. Nothing is routable that was
not routable before, sudoers is closed, and production invocation remains
unauthorised.

Next: **G11-AZ** — a `CROUTE` successor naming `CINST-000003`, then a fresh
`CSEL` derived from that written route. Then **G11-BA** (narrow sudoers and
final preflight) and only then **G11-BB**, the first controlled invoke.
