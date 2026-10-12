# ENG-0005 G11-AY-B — CADV-000004 production write, accepted

**Status: accepted.** `CADV-000004` is written to production and independently
verified from the stored record, not from the CLI's report of itself.

Follows **[G11-AY-A2](2026-09-02-g11-ay-a2-cadv-000004-preparation-96h.md)** (the
96-hour candidate) which superseded
**[G11-AY-A](2026-09-02-g11-ay-a-cadv-000004-preparation.md)** (48 hours, never
frozen, never installed).

Branch `arch/eng-0005-execution-transition`, HEAD `ba56400`.

---

## 1. The record, read from production

`/var/lib/kyri/fabric/capability-advertisements/CADV-000004.yaml` —
`cschott:cschott 0600`, **925 bytes**, stored digest
`965499a3dace61d620b3d6a00bbc59a0655bceaeedcdd0ca879e8245574af708`.

| governed field | required | stored | |
| --- | --- | --- | --- |
| `advertisement_id` | `CADV-000004` | `CADV-000004` | ✓ |
| `supersedes` | `CADV-000003` | `CADV-000003` | ✓ |
| `capability_host_id` | `CHOST-0001` | `CHOST-0001` | ✓ |
| `capability_package_id` | `CPKG-0001` | `CPKG-0001` | ✓ |
| `contract_id` | `CCON-0001` | `CCON-0001` | ✓ |
| `observed_at` | `2026-09-02T12:02:14-05:00` | same | ✓ |
| `valid_until` | `2026-09-06T12:02:14-05:00` | same | ✓ |
| `satisfied_contract_versions` | `["1.0.0"]` | same | ✓ |
| `advertised_resource_profile` | `{architecture: x86-64}` | same | ✓ |
| `approving_authority` | absent | `null` | ✓ |

The record's own evidence carries request digest
`sha256:77025249d1385ec316dc8ebebdf8010b4c5e3107f4b0eb32494e1601667ae834` — the
**same** digest reported by the AY-A2 fixture preflight, the fixture write, the
live preflight, the operator's frozen-input preflight and the write. Six
independent runs, one value.

`reason_category: supersession`, `causal_references: [CHOST-0001, CPKG-0001,
CCON-0001, CADV-000003]`.

The frozen input remains at `/etc/kyri/fabric/cadv-000004.json`,
`root:cschott 0640`, 672 bytes, `130b3724…b9ecc4` — the reviewed candidate,
unchanged by the write.

## 2. Sequence

```
capability-advertisement.seq   3  ->  4
```

Instance, route and selection sequences unmoved at **2 / 2 / 1**.

## 3. Head

Derived, not assumed. Of the four advertisements, three appear as a `supersedes`
target and exactly one does not:

```
records    : CADV-000001, CADV-000002, CADV-000003, CADV-000004
superseded : CADV-000001, CADV-000002, CADV-000003
heads      : CADV-000004        (exactly one)
```

`CADV_HEAD = CADV-000004`. No fork, no ambiguity.

**`CADV-000003` is superseded and byte-identical.** Its digest before and after
the write is `f2b48c2efbe6c1f547f538c6686b1dd0aa24fcbee664ac7ea08c6f5aa2e7116d`.
The supersession is recorded in the *successor's* `supersedes` field; the
predecessor was not edited, which is the append-only model working as ADR-0012
states it: *"Superseded records remain readable. Nothing is edited."*

## 4. Exact mutation accounting

Content manifest, taken before the operator's freeze and again now:

```
CREATE   ./capability-advertisements/CADV-000004.yaml
REPLACE  ./sequences/capability-advertisement.seq
REMOVE   (none)
unchanged  20 of 21 pre-existing objects
```

**Exactly the intended delta.** One record created, one sequence authority
replaced, nothing else.

The sequence file is a **same-size** replacement — `3` and `4` are both one byte.
A structural manifest counting files and sizes would have reported *no change at
all*. That is why prior ceremonies established the content manifest, and this is
the case that would have hidden from anything weaker.

## 5. Surfaces this write did not touch

| | |
| --- | --- |
| Trust content manifest | **byte-identical** |
| `CINST-000001`, `CINST-000002` | unchanged; sequence 2 |
| `CROUTE-0001`, `CROUTE-0002` | unchanged; sequence 2 |
| `CSEL-000001` | unchanged; sequence 1 |
| implementation authority | `8162164a…` unchanged |
| runtime | 79 library objects, `helpers.py` `74b84015…` = Generation 14 |
| identity authorities | `3dec888c…` / `891beeeb…` unchanged |
| helper compatibility | **`compatible`**, 0 blocking |
| sudoers non-`README` | 0 |
| CINV / CRES | 0 / 0 |

`FABRIC_VALID = YES` — `validate` reports `status: reported`, **zero findings**,
counts 4 / 2 / 2 / 1 for advertisements, instances, routes, selections.

## 6. What this does not restore

The Fabric chain is renewed at its *advertisement* only. `CINST-000002` still
names `CADV-000003`, and `CROUTE-0002` still names `CINST-000002`. Nothing is
routable that was not routable before, sudoers is closed, and production
invocation remains unauthorised.

Next: **AY-C** derives `CINST-000003` from this stored record — not from the
candidate JSON — and **AY-D** writes it.
