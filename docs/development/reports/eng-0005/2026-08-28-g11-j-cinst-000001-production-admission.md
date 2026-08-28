# ENG-0005 G11-J — CINST-000001 Production Admission

**Date:** 2026-08-28
**Checkpoint:** G11-J
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Record the completed production admission of `CINST-000001`
durably, and verify it independently and read-only — without taking the
ceremony's own output on trust. Then derive, from committed architecture, what
the next production object is.

**Outcome: ACCEPTED.**

The first governed capability binding in the fabric exists. `CINST-000001`
binds `CPKG-0001` to `CHOST-0001` for `CCON-0001`, admitted against
`CADV-000002` under the trust standings `TREC-000002` and `TREC-000001`.

Every one of the fifteen required verifications passes (§7). The strongest
result is not a digest match but a **mtime proof**: exactly **two** files under
the Fabric authority were written by this ceremony — the record and its
sequence — and nothing else moved (§8).

- **Digest continuity is unbroken** across frozen input → preflight → write →
  durable record (§5).
- The **effective scope was independently re-derived** through the real Trust
  adapter and equals the stored scope exactly (§9).
- **`CADV-000002` remains the chain head** and the named admission
  advertisement (§10).
- **Trust, Artifact, Platform Evidence, the installed runtime, and both CADV
  records are byte-identical** to the G11-I pre-admission capture (§11).

**Two findings are recorded rather than glossed:**

1. **The R17 tail is real and dated** (§12). From `2026-08-29T09:24:51-05:00`
   the advertisement lapses while the admission window runs another 4h 21m, and
   during that period `CINST-000001` is **admitted but not eligible**.
2. **I am correcting my own prior figure.** G11-H and G11-I both said "eight of
   eleven write operations lack permanent preflight coverage." That was wrong in
   both directions. The accurate count is **six of eleven**, and the named list
   was partly incorrect (§15).

`create-route` **is** one of the uncovered six, which makes it a **blocker for
the route ceremony** if a preflight is to gate that write (§15).

---

## 2. Operator ceremony sequence

Performed by the operator. **Not repeated, not altered, and not re-run by this
checkpoint.**

```
1.  freeze     /etc/kyri/fabric/cinst-000001.json   (root:cschott 0640)
2.  preflight  admit-instance --preflight            -> would_accept true
3.  write      admit-instance                        -> accepted, CINST-000001
```

Exactly **one** production `admit-instance` was run.

---

## 3. Frozen operator input

```
/etc/kyri/fabric/cinst-000001.json
sha256  b81e828272b3d8256be8a1d418489f9747c1a3b1d6156c4d77145d7d5d826cda
owner   root:cschott
mode    0640
```

**Verified now, independently:** the digest matches the value reviewed and
frozen in G11-I §9 exactly, and the metadata matches the convention every other
operator input in `/etc/kyri/fabric` carries. The reviewed bytes are what the
operator published, and they are still on disk unchanged.

---

## 4. Production preflight result

As reported by the operator, and consistent with the G11-I rehearsal:

```
outcome              preflight
would_accept         true
rehearsal_reason     null
mutated              false
predicted_record_id  CINST-000001
destination_exists   false
request_digest       sha256:7bd24c86…49da1a
```

This is the gate that **refused** in G11-G with
`supersedes-different-capability`, and that R15 corrected in G11-H. Its passing
here is the first time a first-admission preflight has gated a real production
write.

## 5. Production write result, and digest continuity

```
outcome        accepted
reason         null
record_id      CINST-000001
record_kind    capability-instance
request_digest sha256:7bd24c8669e633896d20ef93c68975310ed16253d9939dc2ca2029b36949da1a
```

The request digest is **identical at every stage**, and the last link is
verified here from the durable record rather than taken from the ceremony
output:

| Stage | Request digest |
|---|---|
| G11-I fixture rehearsal | `sha256:7bd24c86…49da1a` |
| G11-I fixture write | `sha256:7bd24c86…49da1a` |
| G11-I production preflight (isolated dir) | `sha256:7bd24c86…49da1a` |
| Operator production preflight (frozen input) | `sha256:7bd24c86…49da1a` |
| Operator production write | `sha256:7bd24c86…49da1a` |
| **`CINST-000001.yaml` `evidence.request_digest`** | **`sha256:7bd24c86…49da1a`** |

One digest from rehearsal to durable record. **The body that was reviewed is the
body that was admitted** — no substitution occurred at any handoff.

---

## 6. The durable record

`/var/lib/kyri/fabric/capability-instances/CINST-000001.yaml`, in full:

```yaml
admission_decision_id: eng-0005-cinst-000001-admission
admitted_at: '2026-08-28T13:46:27-05:00'
admitted_until: '2026-08-29T13:46:27-05:00'
advertisement_id: CADV-000002
capability_host_id: CHOST-0001
capability_id: CAPDEF-0001
capability_package_id: CPKG-0001
contract_id: CCON-0001
effective_scope:
  permitted_capabilities:
  - CAPDEF-0001
  permitted_data_classifications:
  - internal
  permitted_operations:
  - execute
  permitted_targets:
  - HOST-0001
evidence:
  actor: primary-platform-operator
  approving_authority: primary-platform-operator
  causal_references:
  - CAPDEF-0001
  - CCON-0001
  - CPKG-0001
  - CHOST-0001
  - CADV-000002
  reason_category: instance-admission
  recorded_at: '2026-08-28T13:46:27-05:00'
  request_digest: sha256:7bd24c8669e633896d20ef93c68975310ed16253d9939dc2ca2029b36949da1a
  request_id: g11i-admit-instance-cpkg-0001-chost-0001-cadv-000002
  trust_evidence_references:
  - TREC-000002
  - TREC-000001
host_trust_record_id: TREC-000001
instance_id: CINST-000001
kind: capability-instance
lifecycle_state: admitted
package_trust_record_id: TREC-000002
provenance:
  class: declared
  recorded_at: '2026-08-28'
  source: docs/decisions/ADR-0012-distributed-capability-fabric.md
satisfied_contract_versions:
- 1.0.0
schema_version: schott-platform/v1
verified_resource_profile:
  architecture: x86-64
```

```
CINST_SHA256  92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729
mode          rw------- (0600), cschott:cschott
written       2026-08-28 13:57
```

`supersedes` is absent and `superseded_by` is absent — this is a first
admission and a chain root, exactly as G11-I prepared.

---

## 7. The fifteen required verifications

| # | Check | Result |
|---|---|---|
| 1 | `CINST-000001` exists exactly once | **PASS** — 1 record in `capability-instances/` |
| 2 | `capability-instance.seq == 1` | **PASS** |
| 3 | durable SHA-256 matches `92eba1c3…1e729` | **PASS** |
| 4 | request digest matches the frozen/preflight/write lineage | **PASS** (§5) |
| 5 | references exactly CAPDEF/CCON/CPKG/CHOST/CADV-000002/TREC-000002/TREC-000001 | **PASS** |
| 6 | effective scope matches the real Trust intersection | **PASS** — re-derived (§9) |
| 7 | `CADV-000002` remains the named admission advertisement | **PASS** (§10) |
| 8 | `CADV-000001` and `CADV-000002` unchanged | **PASS** (§11) |
| 9 | Trust validates clean | **PASS** — `valid: true`, `problems: []` |
| 10 | Artifact authority unchanged | **PASS** (§11) |
| 11 | Platform Evidence unchanged | **PASS** (§11) |
| 12 | installed runtime unchanged | **PASS** — 57 objects, 9-file closure |
| 13 | CROUTE count == 0 | **PASS** |
| 14 | CSEL count == 0 | **PASS** |
| 15 | Root Authority unmounted | **PASS** |

### Fabric inventory

```
capability-definitions    1   CAPDEF-0001
capability-contracts      1   CCON-0001
capability-packages       1   CPKG-0001
capability-hosts          1   CHOST-0001
capability-advertisements 2   CADV-000001, CADV-000002
capability-instances      1   CINST-000001          <- new
capability-routes         0
capability-selections     0

sequences: advertisement 2, contract, definition, host, instance 1, package,
           request_identity.lock                     <- instance sequence is new
```

---

## 8. What the ceremony actually wrote

The decisive proof, independent of any digest baseline. Every file under the
Fabric authority modified during the ceremony window:

```
2026-08-28 13:57  /var/lib/kyri/fabric/capability-instances/CINST-000001.yaml
2026-08-28 13:57  /var/lib/kyri/fabric/sequences/capability-instance.seq

files touched: 2   (expected: exactly the record and its sequence)
```

**Exactly two files, and they are exactly the two an accepted `admit-instance`
must write.** No other record, no other sequence, no lock residue, no temporary.
The whole-tree Fabric digest necessarily changed — `6428520119fd…` →
`4d95072bf3cc…` — and this is what accounts for the change, completely.

---

## 9. Effective scope, independently re-derived

Not read back from the record and asserted — recomputed from the live Trust
plane through the real helpers, at the instant the decision used
(`admitted_at`):

```
_verified_standing(trust, TREC-000002, admitted_at, capability-package)
    -> verified, subject_id = CPKG-0001
_verified_standing(trust, TREC-000001, admitted_at, fabric-node)
    -> verified, subject_id = HOST-0001

_effective_scope(package.scope, host.scope, admission_scope):
    permitted_capabilities          ['CAPDEF-0001']
    permitted_data_classifications  ['internal']
    permitted_operations            ['execute']
    permitted_targets               ['HOST-0001']

re-derived == stored effective_scope : True
```

And the two subject bindings admission enforces:

```
package standing subject == capability_package_id     : True  (CPKG-0001)
host standing subject    == node_identity_reference   : True  (HOST-0001)
host node identity in permitted_targets  (G11-A2)     : True  (HOST-0001)
```

**G11-A2 holds in the durable record.** The comparison is against
`CHOST-0001.node_identity_reference` = `HOST-0001`, never against `CHOST-0001`
itself — two namespaces the platform deliberately refuses to equate.

---

## 10. `CADV-000002` — still head, still the named advertisement

```
advertisement_head(store, "CADV-000002")  ->  CADV-000002
CINST-000001.advertisement_id             ->  CADV-000002
named advertisement is still head         ->  True
```

Under R16 this was a **mandatory precondition** of the admission, not an
observation, and it still holds after the write. The instance is permanently
bound to the claim it was admitted against — the G11-A1 doctrine — and that
claim is still the current one.

---

## 11. Production authority outside the CINST

Compared against the G11-I pre-admission capture:

| Authority | Digest | |
|---|---|---|
| Trust | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | **UNCHANGED** |
| Artifact | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | **UNCHANGED** |
| Platform Evidence | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | **UNCHANGED** |
| Installed runtime | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | **UNCHANGED** |
| `CADV-000001` | `cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195` | **UNCHANGED** |
| `CADV-000002` | `555f9a8d35c6cbd92ccb3041a6ed2946809f3704d0a320b3d7ae198320722454` | **UNCHANGED** |
| Fabric (whole tree) | `6428520119fd…` → `4d95072bf3cc…` | changed — accounted for in §8 |

```
Trust validate-store : valid true, problems []
                       audit 4, authority 1, decision 2, evidence 7,
                       lineage 3, record 2
installed runtime    : 57 objects, 9-file Fabric closure
Root Authority       : unmounted
```

**Admitting an instance consumed two trust standings and moved neither.** Trust
is read at admission and never written by it — the standings are referenced in
the instance's evidence, not altered.

**This audit itself mutated nothing.** Every command ran read-only as uid 1000;
no privileged operation was performed.

---

## 12. Clock audit, and the R17 tail

```
report time                    2026-08-28T14:04:50-05:00

CADV-000002  observed_at       2026-08-28T09:24:51-05:00
             valid_until       2026-08-29T09:24:51-05:00   19h 20m   FRESH
CINST-000001 admitted_at       2026-08-28T13:46:27-05:00
             admitted_until    2026-08-29T13:46:27-05:00   23h 41m   VALID
```

Both are currently live. **Neither was altered by this checkpoint.**

### The accepted R17 consequence, stated precisely

R17 decoupled the two clocks, so the admission window outlives the
advertisement:

```
R17 tail:  2026-08-29T09:24:51-05:00  ->  2026-08-29T13:46:27-05:00   (4h 21m 36s)
currently inside the tail: NO
```

During that window `CINST-000001` will be **admitted but not eligible.**
`eligibility.py` ELIG-6 — *"A claim that exists, is registered, and is inside its
window"* — resolves the instance's named `advertisement_id` and checks
`observed <= instant < expires`, returning `advertisement-not-fresh` otherwise.
The instance names `CADV-000002` permanently, so once that advertisement lapses,
ELIG-6 is unmet.

**This is expected, not a defect.** It is the direct and intended consequence of
R17's ruling that admission expiry and advertisement expiry are independent
clocks. Admission asks *may this binding exist*; eligibility asks *may it serve
right now*. They are different questions with different answers, and the record
is immutable either way.

**The operational consequence is worth stating plainly:** after
`2026-08-29T09:24:51-05:00`, `CINST-000001` becomes permanently ineligible for
selection. `automatic_renewal` and `automatic_readmission` are both `forbidden`
and `recovery: requires-new-decision`, so restoring eligibility requires a fresh
advertisement **and a new instance admission against it** — not a repair of this
record. That sets a real deadline on the selection ceremony (§16).

---

## 13. Next-object derivation

Derived from committed source, schemas and ADR-0012 — **not assumed from the
brief**.

**The next production object is `CROUTE-000001`, and it must precede
`CSEL-000001`.**

The dependency is not stylistic. `tools/fabric/selection.py::_resolve_route`
matches a route on capability, contract, accepted version set, classification
and locality, and returns `None` when none matches; a selection with no route
resolves to no candidate. **Selection cannot bind anything without a route.**

### Exact role of CROUTE

From `create_route`'s own docstring:

> *"Declare which admitted bindings may serve a request class, in order. **The
> order is written by a human and stored.** Nothing here derives it, and nothing
> here consults load, latency, success rate, health, or any other measurement —
> a router that orders candidates by observed behaviour is deriving placement
> from reasoning."*

A route is the operator's declared, ordered candidate list for one request
class. `selection.py` takes the first eligible candidate in declared order;
there is no tie-break because declared order is already total.

### Relationship to CINST

`create_route` requires, for every named candidate:

| Rule | Refusal | `CINST-000001` |
|---|---|---|
| candidate resolves as a `capability-instance` | `unresolved-reference` | ✓ |
| `capability_id` and `contract_id` match the route's | `candidate-not-of-capability` | ✓ `CAPDEF-0001` / `CCON-0001` |
| candidate is a **binding root** (`_binding_root == candidate`) | `candidate-not-a-binding-root` | ✓ `supersedes` absent |
| `lifecycle_state == "admitted"` | `candidate-not-a-binding-root` | ✓ `admitted` |

*"A route targets admitted bindings only: targeting an advertisement would mean
routing to a self-report, and targeting a withdrawn binding would mean routing
to a decision somebody already reversed."*

**`CINST-000001` satisfies every candidate rule today.**

### Does route creation consume Trust?

**No.** The signature is `create_route(store, *, ...)` — there is **no
`trust_store` parameter**, and the CLI registers it as
`"create-route": ("create_route", False)`, i.e. `needs_trust=False`. Trust was
consumed once, at admission, and the route routes to the binding that already
carries it.

### Does a route have expiry or currentness?

**No expiry. Currentness only.** The route schema declares no `valid_until` and
no validity window; the required fields are `route_id`, `route_version`,
`capability_id`, `contract_id`, `accepted_contract_versions`, `locality`,
`candidate_instances`, `data_classification`, `provenance`. The optional
`overlap_window` is **not** route validity — it is a cutover assertion, permitted
only when superseding and only when the candidate lists genuinely show both a
carried and an arrived candidate.

Currentness is by supersession chain, read by `_chain_heads`, plus a strictly
increasing `route_version`. Two current routes for one request class is refused
as `route-ambiguous` rather than resolved — *"a policy question nobody answered,
and answering it here would be the selection deriving its own authority."*

### Is a fresh CADV required at route creation?

**No.** `create_route` contains **zero** references to `capability-advertisement`
— it never resolves one. Advertisement freshness enters only at **selection**,
through ELIG-6.

So the advertisement clock constrains `CSEL-000001`, **not** `CROUTE-000001`.

### Vocabularies the route body must use

```
LOCALITIES                     ('local-only', 'operator-controlled-only', 'any-trusted')
WORKLOAD_DATA_CLASSIFICATIONS  ('internal',)
route_version                  an int >= 1
```

**A caution for the route ceremony:** `CHOST-0001.location_class` is
`on-premises`, which belongs to a **different vocabulary** than the route's
`locality`. They are not interchangeable, and a route body must use one of the
three `LOCALITIES` tokens.

### Known blockers before `CROUTE-000001`

- **No authority blocker.** Every input the route needs exists and qualifies.
- **One process blocker: preflight coverage** — §15.

---

## 14. Preflight coverage — correcting my own figure

G11-H §18 and G11-I §20 both stated that **"eight of eleven write operations
lack permanent preflight coverage,"** and G11-H named them. **That was wrong in
both directions**, and I am correcting it here rather than repeating it.

The error came from a loose search: I counted operations that appeared in the
same suite as a `--preflight` call, instead of checking which operation each
preflight actually drives. `tests/test-fabric-preflight.sh`, for instance, names
its operation once inside a `run()` helper far from every call site, so a
window-based scan misses it entirely.

**Accurate coverage, verified per operation** — a suite counts only if a
`--preflight` invocation or a `rehearsing()` block actually drives that
operation:

| Operation | Permanent preflight coverage |
|---|---|
| `declare-capability` | ✓ `test-fabric-preflight.sh` (CLI) |
| `declare-contract` | ✓ `test-fabric-runtime.sh` (rehearsing) |
| `declare-package` | ✓ `test-artifact-authority.sh`, `test-fabric-package-manifest.sh` |
| `admit-subject` | ✓ `test-fabric-preflight.sh` (CLI), `test-fabric-host-admission.sh`, `test-fabric-evidence-authority.sh` |
| `admit-instance` | ✓ `test-fabric-instance-admission-integrity.sh` (CLI) — added by G11-H |
| `register-advertisement` | **✗ NONE** |
| **`create-route`** | **✗ NONE** |
| `withdraw-subject` | **✗ NONE** |
| `refresh-subject` | **✗ NONE** |
| `withdraw-instance` | **✗ NONE** |
| `retire-instance` | **✗ NONE** |
| *(`select`, not a write operation)* | ✓ `test-fabric-runtime.sh` — added by G11-C |

**Covered: 5 of 11. Uncovered: 6 of 11.**

G11-H's named list wrongly included `declare-capability`, `declare-contract` and
`admit-subject` — all three *are* covered — and omitted `register-advertisement`,
which is not. The corrected list is the six above.

Notably, **`register-advertisement` has no permanent preflight test** even though
G11-F ran a production preflight of it successfully. Working in production and
being permanently tested are different things, and only the second survives a
future change.

---

## 15. `create-route` preflight status — a blocker for the route ceremony

`create-route` **is** one of the uncovered six.

Structurally the CLI supports it: `"create-route"` appears in `WRITE_OPERATIONS`
and in `CREATED_KINDS` as `capability-route`, so `command_preflight` is reachable
for it. **But no test has ever driven it**, and this checkpoint deliberately did
not rehearse it — the brief limits CROUTE work to read-only source inspection,
and I respected that.

**That makes it a blocker, and the reason is empirical rather than theoretical.**
R15 was a real defect in `admit_instance`'s rehearsal path, found the first time
anyone actually preflighted that operation, and it refused a valid body with a
misleading reason. `create-route` has never had its rehearsal path exercised by
anything. Whether it works today is **unverified**.

**Recommendation:** if a preflight is to gate the first `CROUTE` production write
— and on the precedent of G11-G it should — then a corrective checkpoint must
first add permanent `create-route --preflight` coverage, exactly as G11-H did for
`admit-instance`. That checkpoint should establish RED honestly: it may find
nothing wrong, and that is a fine outcome; what it must not do is discover a
defect during the ceremony.

---

## 16. Actions NOT performed

- **No second CINST created.** `capability-instance.seq` is 1 and one record
  exists.
- **The production admission was not repeated.** No `admit-instance` was run by
  this checkpoint.
- **No CROUTE created, and none rehearsed** — source inspection only, per the
  brief.
- **No CSEL created. No CADV-000003. No package staged, no capability invoked.**
- **Trust, Artifact and Platform Evidence not mutated** — and Trust was not
  written by the admission either (§11).
- **`CADV-000001` and `CADV-000002` not modified.**
- **Installed runtime not modified; Generation 11 not reinstalled.**
- **Root Authority not mounted.**
- **No source change.** This checkpoint commits a report and nothing else.
- **No privileged operation, no `sudo`.**
- **No secrets recorded.**

---

## 17. Remaining blockers and backlog

1. **`create-route` preflight coverage** — blocker for the route ceremony
   (§15).
2. **Five further uncovered preflight paths** — `register-advertisement`,
   `withdraw-subject`, `refresh-subject`, `withdraw-instance`, `retire-instance`
   (§14). Not blocking now; each becomes blocking the first time its operation
   is used in production.
3. **The selection deadline** — after `2026-08-29T09:24:51-05:00`,
   `CINST-000001` is permanently ineligible and a new advertisement **plus a new
   instance admission** would be required (§12). This is the binding constraint
   on `CSEL-000001`, and it is tighter than it looks.
4. **No durable admission-window policy surface** — R17 settled the bootstrap
   value and deliberately declined to create one.
5. **`data-classification-not-permitted-by-host` remains unreachable** — both
   grants carry only `internal`, and `WORKLOAD_DATA_CLASSIFICATIONS` has exactly
   one member. An artifact of a single-classification fabric.
6. **Carried forward, unrelated:** the Artifact digest discrepancy (G11-D §18,
   G11-E §18) and the two lagging execution helper modules (G11-E §10.1).

---

## 18. Recommended next checkpoint

**A corrective checkpoint adding permanent `create-route --preflight`
coverage**, before any route ceremony — RED first, on the G11-H pattern.

Then, in order:

1. **`CROUTE-000001`** — declare `CINST-000001` as the sole candidate for the
   `CAPDEF-0001` / `CCON-0001` / `1.0.0` / `internal` request class at a locality
   chosen from `LOCALITIES`. No Trust consumed, no advertisement referenced, no
   expiry clock. Rehearse, freeze, preflight, write.
2. **`CSEL-000001`** — the first governed selection, rehearsed through the
   G11-C read-only selection preflight before the identity is spent.

### The scheduling question the reviewer should decide

Step 2 is gated by the advertisement clock and steps 0–1 are not. Realistically,
a corrective preflight checkpoint plus a route ceremony will not complete before
`2026-08-29T09:24:51-05:00`, so `CSEL-000001` will almost certainly need a fresh
lineage:

```
CADV-000003 supersedes CADV-000002       (G11-F renewal path, proven)
CINST-000002 admitted against CADV-000003 (this ceremony, repeated)
CROUTE naming CINST-000002
CSEL against that route
```

**That is not a failure of this checkpoint.** `CINST-000001` is a correct,
permanent, governed record and the first binding the fabric has ever held. But
the reviewer should decide deliberately whether to race the current window or to
plan the renewal — rather than discovering the constraint mid-ceremony. **Do not
weaken freshness to avoid it.**

---

## Appendix A — commands executed

All read-only. **No `sudo`. Nothing written to any production path.**

```bash
# Authority
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <a944cd9|0c31db8|33650bf> HEAD

# The CINST itself
ls -la /var/lib/kyri/fabric/capability-instances/
sha256sum /var/lib/kyri/fabric/capability-instances/CINST-000001.yaml
cat       /var/lib/kyri/fabric/capability-instances/CINST-000001.yaml
cat /var/lib/kyri/fabric/sequences/capability-instance.seq          # 1
find /var/lib/kyri/fabric -type f -newermt '2026-08-28 13:00'       # exactly 2

# Frozen input, authorities, runtime
sha256sum /etc/kyri/fabric/cinst-000001.json ; stat -c '%U:%G %a' ...
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# Independent re-derivation
python3 -c "<_verified_standing x2, _admission_scope, _effective_scope,
             advertisement_head, node-identity target check>"

# Next-object derivation, from source
sed -n '1789,1935p' tools/fabric/admission.py            # create_route, whole
sed -n '<_resolve_route>' tools/fabric/selection.py
grep -n '"create-route"' tools/fabric/cli.py             # needs_trust False
grep -nE 'route_version|overlap|valid_until' platform-model/schemas/capability-route.schema.yaml
python3 -c "<LOCALITIES, WORKLOAD_DATA_CLASSIFICATIONS>"

# Preflight coverage, per operation and precisely
python3 -c "<for each op: does a --preflight invocation or rehearsing() block
             actually drive it>"
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001  capability
     │
CCON-0001    contract 1.0.0
     │
CPKG-0001    package ──────────────┐
     │                             │
CHOST-0001   host (node HOST-0001) │
     │                             │
     ├── CADV-000001  expired, superseded, retained as history
     │        ↑ supersedes
     └── CADV-000002  CURRENT HEAD, fresh until 2026-08-29T09:24:51-05:00
                  │
                  ▼
            CINST-000001   admitted 2026-08-28T13:46:27-05:00
                           until    2026-08-29T13:46:27-05:00
                           trust    TREC-000002 (package) + TREC-000001 (host)
                           scope    CAPDEF-0001 / execute / internal / HOST-0001
                           digest   92eba1c3…1e729

            CROUTE       ABSENT  <- next object; no Trust, no advertisement,
                                    no expiry. Blocked on preflight coverage.
            CSEL         ABSENT  <- needs a route, and needs the advertisement
                                    fresh at selection time.

THE TAIL:  09:24:51 ─────────── 13:46:27   on 2026-08-29
           advertisement stale, admission still valid
           -> ELIG-6 unmet: admitted, but not eligible. Expected.
```
