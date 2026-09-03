# ENG-0005 G11-AZ-A — CROUTE-0003 preparation

**Status: prepared, awaiting operator freeze.** No production byte was written by
this preparation. The production Fabric content manifest is byte-identical
before and after every check below.

Follows **[G11-AY-D](2026-09-03-g11-ay-d-cinst-000003-production-write.md)**,
which accepted the `CINST-000003` production write. Every value here is derived
from the **stored** records and the **live** allocators, never from a prior
report's expectation.

Branch `arch/eng-0005-execution-transition`, HEAD `53332cf`.

---

## 1. Identifiers, derived from the live store

| | derived from | value |
| --- | --- | --- |
| `CROUTE_NEXT` | `peek_next_id` on the live store | **CROUTE-0003** — destination absent |
| `CROUTE_SUPERSEDES` | the sole unsuperseded route | **CROUTE-0002** |

Head derived, not assumed. Of the two routes, exactly one appears as a
`supersedes` target and exactly one does not:

```
all routes  : CROUTE-0001, CROUTE-0002
superseded  : CROUTE-0001
heads       : CROUTE-0002        (exactly one)
```

The two existing routes, read from production:

```
CROUTE-0001  version=1  candidates=[CINST-000001]  locality=local-only  class=internal  versions=[1.0.0]
CROUTE-0002  version=2  candidates=[CINST-000002]  locality=local-only  class=internal  versions=[1.0.0]
```

`route_version` must exceed the predecessor's, so the candidate declares **3**.

## 2. The candidate names the fresh binding, and only it

`candidate_instances: ["CINST-000003"]`. `CINST-000002` is **not** carried.

The prior accepted ruling stands: a carry-both overlap was wrong because
selection prefers the earlier entry in declared order, so carrying the old
binding would have kept selecting it. That ruling is **not** reintroduced here,
and no overlap window is declared.

**Worth stating plainly: the source does not enforce that ruling.** §4 case G
shows a carry-both route *with* an overlap window is still **accepted**. The
discipline is a ceremony ruling, not a structural refusal, so it has to be held
by review rather than relied on from the engine.

Governed semantics retained unchanged from the predecessor: `capability_id
CAPDEF-0001`, `contract_id CCON-0001`, `accepted_contract_versions ["1.0.0"]`,
`data_classification internal`, `locality local-only`.

## 3. The candidate passes the binding-root rule

`create_route` refuses a candidate that is not its own binding root
(`REASON_NOT_BINDING_ROOT`) and one that is not `admitted`. `CINST-000003` is
its own binding root and is `admitted` — both re-proved against the live store
in AY-D §7. The route may therefore name it.

## 4. Route-head enforcement, exercised against a faithful fixture

A full copy of the live store — `diff -r` clean against production before any
probe, so the history is the real one including `CINST-000003`.

The verdict is read from `rehearsal_outcome` / `would_accept`. **`outcome` is
always `preflight` and says nothing about acceptance** — reading it instead
would report every case as passing, which is exactly the mistake this table is
written to make impossible to repeat.

| | body | `would_accept` | reason |
| --- | --- | --- | --- |
| **A** | **the candidate** — supersedes the current head | **true** | — |
| B | supersedes `CROUTE-0001`, a stale predecessor | **false** | `supersedes-already-superseded` |
| C | no predecessor, class already routed | **false** | `request-class-already-routed` |
| D | `route_version: 2`, not greater than the predecessor | **false** | `invalid-route-version` |
| E | candidate instance that does not resolve | **false** | `unresolved-reference` |
| F | overlap window declared, no coexistence in the lists | **false** | `overlap-window-without-coexistence` |
| G | carry-both `[CINST-000002, CINST-000003]` **with** overlap | **true** | — see §2 |
| H | routes to the superseded `CINST-000002` alone | **true** | — see §8 |

**The three required cases hold: stale predecessor refuses, a second route with
no predecessor refuses, linear current-head supersession accepts.** No fork is
reachable through the released path.

**The fixture write then succeeded**, producing `CROUTE-0003` with
`route_version: 3`, `candidate_instances: [CINST-000003]`,
`supersedes: CROUTE-0002`, `reason_category: supersession`, `causal_references:
[CAPDEF-0001, CCON-0001, CINST-000003, CROUTE-0002]`, and **no**
`overlap_window`. The fixture Fabric validated with **zero findings**, counts
4 / 3 / 3 / 1.

## 5. Live preflight

Read-only against production:

```
predicted_record_id : CROUTE-0003
destination         : /var/lib/kyri/fabric/capability-routes/CROUTE-0003.yaml
destination_exists  : false
would_accept        : true
mutated             : false
request_digest      : sha256:970d926ccdafce77cac9d7c1869b61c8f744515847172780b45849de3fd4a3dc
```

The request digest is identical across the fixture preflight, the fixture write
and this live preflight — one value for the operator to compare.

**Non-mutation:** the production Fabric content manifest is
`f56503b280d4b86f1eb9addfcc5d98eda128e1a346ef07076c90219f1086e56d` before and
after, which is also the post-AY-D value. Nothing has touched the store since
the accepted instance write.

## 6. The candidate

| | |
| --- | --- |
| bytes | **677** |
| SHA-256 | `724ec6c2c71330e713b7df691dc025a3a4253cf3e6aef756debd301ab0d29976` |
| request digest | `sha256:970d926ccdafce77cac9d7c1869b61c8f744515847172780b45849de3fd4a3dc` |
| destination | `/etc/kyri/fabric/croute-0003.json`, `root:cschott 0640` |
| `recorded_at` | `2026-09-03T06:44:11-05:00` |

```json
{
  "request_id": "g11az-create-route-capdef-0001-ccon-0001-cinst-000003-supersedes-croute-0002",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-03T06:44:11-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000003"
  ],
  "data_classification": "internal",
  "route_version": 3,
  "supersedes": "CROUTE-0002",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-03"
  }
}
```

## 7. Operator block — freeze only

Fail-if-exists. It writes the reviewed input and preflights it. It performs
**no** Fabric write.

```bash
bash <<'FREEZE_CROUTE'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/croute-0003.json
REVIEWED=724ec6c2c71330e713b7df691dc025a3a4253cf3e6aef756debd301ab0d29976

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11az-create-route-capdef-0001-ccon-0001-cinst-000003-supersedes-croute-0002",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-03T06:44:11-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000003"
  ],
  "data_classification": "internal",
  "route_version": 3,
  "supersedes": "CROUTE-0002",
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
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file croute-0003.json --approved-directory /etc/kyri/fabric --preflight
FREEZE_CROUTE
```

Expect 677 bytes at `724ec6c2…29976`, and a preflight reporting
`would_accept: true`, `mutated: false`, `predicted_record_id: CROUTE-0003` and
request digest `sha256:970d926c…d4a3dc` — **the same digest as §5**.

**Read `would_accept`, not `outcome`.** `outcome` reads `preflight` whether the
rehearsal accepted or refused.

The Fabric write is **not** in this block. It is authorised separately.

## 8. Selection must wait for the written route

`CSEL_NEXT = CSEL-000002`, from the live allocator.

**`CSEL_PREPARATION = DEFERRED_UNTIL_ROUTE_WRITE`**, and this is not caution —
it is what the engine does.

A selection input names a **request class**, never a `route_id`. The route is
resolved from the class at selection time, so the same reviewed bytes mean
different things before and after the route write. Demonstrated with one input
against two stores:

| store | route resolved | `selected_instance_id` |
| --- | --- | --- |
| **live production** (head `CROUTE-0002`) | `CROUTE-0002` | **`null`** |
| fixture (head `CROUTE-0003`) | `CROUTE-0003` | **`CINST-000003`** |

**The request digest is `sha256:65fe4741…c338088` in both cases.** It covers the
caller's inputs, not the resolved route — so the digest **cannot** witness which
route a selection bound to. A frozen `CSEL` reviewed today would carry the same
digest whether it landed before or after the route write. The written record's
`route_id` and `selected_instance_id` are the only evidence that distinguishes
them, and they exist only after the write.

**Selecting now would be accepted, and would spend `CSEL-000002` on a refusal.**
Run against a throwaway copy of the live store, it returns `outcome: accepted`
with `selected_instance_id: null` and stores:

```
selection_id      CSEL-000002
route_id          CROUTE-0002
refusal_reason    no-eligible-candidate
reason_category   selection-refusal
excluded_candidates
  CINST-000002 : advertisement-not-fresh, admission-window-expired
```

Selections are immutable, so that identifier would be permanently consumed by a
record naming the *old* route. `CINST-000002` is excluded because it is bound to
the expired `CADV-000003` window — confirmed independently:
`compute-eligibility` for `CINST-000002` now reports `eligible: false`, unmet
`ELIG-6` and `ELIG-7`.

**So the order is not a preference.** `CROUTE-0003` is written and independently
verified first; only then is `CSEL-000002` derived from the live written route.
No selection candidate is frozen by this preparation.

## 9. Production state

```
CROUTE-0003 (record)               absent
seq(capability-route)              2
/etc/kyri/fabric/croute-0003.json  absent
CROUTE head                        CROUTE-0002, candidate_instances [CINST-000002]
CINST head                         CINST-000003 (admitted, eligible, own binding root)
CSEL-000001                        unchanged, e08a4df4…e79bb
sudoers non-README                 0
CINV / CRES                        0 / 0
helper compatibility               compatible, 8 declared, 0 blocking
Root Authority                     unmounted
```

`NEW_INSTANCE_ROUTABLE = NO` until the route write lands.
`PRODUCTION_INVOKE_AUTHORISED = NO`.

## 10. Follow-up recorded, not acted on

Two behaviours were observed during this preparation. **Neither is a defect in
this candidate and neither was changed here.**

1. **A route may name a superseded instance** (§4 case H). `create_route`
   refuses a candidate that is not its own binding root or not `admitted`, but
   supersession disqualifies neither — `CINST-000002` is still its own binding
   root and still `admitted`. This is precisely why the route did not follow the
   instance renewal on its own, and why AY-D left a head route pointing at a
   stale binding. Eligibility catches it later, at selection, rather than
   structurally at route creation.
2. **A carry-both overlap is still accepted** (§2, §4 case G), so the ruling
   against it is held by review only.

Both belong to route hardening, alongside the withdrawn-binding route issue
already on record, and the silent scope-narrowing noted in AY-C §5. They are
listed so they are not rediscovered as surprises.

## 11. Next

1. Operator freezes the reviewed `CROUTE-0003` input with §7 and returns the
   output.
2. Independent verification of the frozen input, then a separately authorised
   single production route write.
3. Only then `CSEL-000002`, derived from the **live written** `CROUTE-0003`.
4. Then **G11-BA** — narrow sudoers and final preflight. Then **G11-BB**, the
   first controlled invoke.

`CSEL-000001` is historical and immutable; it is not modified at any point.
