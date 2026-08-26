# ENG-0005 G11-A — Instance Admission Integrity and Advertisement Renewal

**Date:** 2026-08-26 (started and completed)
**Checkpoint:** G11-A
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Close the three source and model blockers that must be resolved
before the first capability instance can safely be admitted:

- **G11-A1** — `CapabilityInstance.advertisement_id` must be mandatory.
- **G11-A2** — `admit_instance` must require the admitted host to belong to
  `effective_scope["permitted_targets"]`.
- **G11-A3** — provide a governed immutable advertisement renewal/supersession
  mechanism before `CADV-000002` may exist.

RED-first, no production mutation.

**Outcome: ACCEPTED.** All three are closed, RED-first, with a dedicated suite
of 91 assertions. The full validator passes **92/92** from the clean
implementation commit. **No production state changed**: `CADV-000001` is
byte-identical, `CADV` count is 1, there is no `CADV-000002`, `CINST` is 0 with
its sequence absent, and `CROUTE`/`CSEL` are 0.

Three findings emerged that were not in the brief and are recorded rather than
smoothed over:

1. **`superseded_by` is written by no released operation, for any of the seven
   record classes.** The head is derived by reverse lookup over `supersedes`.
   Ruling in §7.
2. **Two refusal reasons drafted during the work were unreachable and were
   removed** — `renewal-changes-contract` and `renewal-supersedes-itself`. §8.
3. **A pre-existing, unrelated validator failure** in three G5 suites, caused by
   commit-depth drift. Fixed in its own commit. §12.

---

## 2. Interruption recovery

**A subscription interruption occurred while implementing G11-A3**, immediately
after the edit that removed the unreachable `renewal-changes-contract` reason.
The checkpoint was resumed in the same session and working tree. **No work was
discarded, reset, stashed, or blindly repeated.**

### Surviving working-tree state

```
$ git rev-parse HEAD          e031cc298188fc3c16bc149d5646cca9f073d0ca
$ git rev-parse --abbrev-ref  arch/eng-0005-execution-transition
$ git status --short
   M platform-model/schemas/capability-instance.schema.yaml
   M tools/fabric/admission.py
   M tools/fabric/models.py
  ?? tests/test-fabric-g11-integrity.sh          (576 lines)
$ git diff --check                                PASS
$ git diff --stat        3 files changed, 131 insertions(+), 5 deletions(-)
```

Exactly the state described as pre-interruption.

### Recovery checks performed

Completeness was verified before any further change — an interrupted edit could
have truncated a file mid-write:

```
PASS  tools/fabric/admission.py parses
PASS  tools/fabric/models.py parses
PASS  platform-model/schemas/capability-instance.schema.yaml loads
PASS  platform-model/schemas/capability-advertisement.schema.yaml loads
PASS  tests/test-fabric-g11-integrity.sh is valid bash
PASS  admission imports cleanly

advertisement_head present        : True
REASON_TARGET_SCOPE               : target-not-permitted-by-scope
REASON_RENEWAL_HOST               : renewal-of-another-host
REASON_RENEWAL_PACKAGE            : renewal-changes-package
REASON_RENEWAL_SELF               : renewal-supersedes-itself
REASON_RENEWAL_NOT_HEAD           : renewal-predecessor-not-current
REASON_ADVERT_FORKED              : advertisement-chain-forked
REASON_RENEWAL_CONTRACT removed   : True
register_advertisement supersedes : True
```

**The final pre-interruption edit had completed cleanly.**

### First focused-test result after recovery

The suite was run before anything else was changed:

| Section | Result |
|---|---|
| G11-A1 | **all GREEN** (schema, model, admission, round trip) |
| G11-A2 | **all GREEN** (accept, refuse, distinct reason, no allocation, no sequence) |
| G11-A3 | **GREEN** through the package-change case, then **ERROR** |

The single failure was an **ERROR, not an intended RED**: the test still
referenced `A.REASON_RENEWAL_CONTRACT`, which the last surviving edit had
deliberately removed. The assertion immediately above it —
*"a renewal changing the contract is refused as a different binding"* — already
passed, so the invariant held; only the test's expectation of *which* reason was
stale. Distinguishing that from a real RED is why the suite was run before any
further edit.

Nothing already working was rebuilt. Work resumed at exactly that assertion.

---

## 3. Starting authority

| Gate | Observed | |
|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD | `e031cc298188fc3c16bc149d5646cca9f073d0ca` | PASS |
| Trust | `valid: true`, `problems: []` | PASS |
| CAPDEF/CCON/CPKG/CHOST/CADV-000001 | all digests unchanged | PASS |
| `CADV-000001` | `cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195` | PASS |
| CINST count | 0; `capability-instance.seq` absent | PASS |
| CROUTE / CSEL | 0 / 0 | PASS |
| `CADV-000002` | absent | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
```

### CADV-000001 freshness

| Moment | State |
|---|---|
| Checkpoint start (`2026-08-26T15:49:32-05:00`) | **FRESH**, 22.41 h remaining |
| Checkpoint completion (`2026-08-26T17:04-05:00`) | **FRESH**, 21.16 h remaining |

Freshness is recorded because it was asked for. **It did not affect the source
corrections in any way** — every correction is about what the platform may
record, judged from governed request values, not about whether an existing claim
is currently inside its window. `CADV-000001` was neither touched nor raced.

---

## 4. G11-A1 — mandatory advertisement identity

### RED

```
model advertisement_id  type='str | None'  default=None
schema: required? False   optional? True
```

`admit_instance` passes `advertisement_id` through `_identifier()`, which
refuses `None` — so the **runtime already required it** while the model and
schema said otherwise. Eight assertions failed:

```
FAIL: the instance schema requires advertisement_id
FAIL: the instance schema no longer lists advertisement_id as optional
FAIL: an instance whose advertisement_id is omitted entirely is refused
FAIL: an instance whose advertisement_id is explicitly null is refused
FAIL: an instance whose advertisement_id is empty is refused
FAIL: an instance whose advertisement_id is outside the CADV grammar is refused
FAIL: an instance whose advertisement_id is an identifier of another kind is refused
FAIL: an instance reloaded without its advertisement is refused
```

### Root cause

A model that is not authoritative about what a valid record is cannot refuse a
record nobody admitted. A hand-built or legacy instance with no advertisement
was constructible, storable and reloadable — and ELIG-6, which asks whether an
instance's advertisement is fresh, could never answer for it.

### Implementation

`tools/fabric/models.py` — the field becomes required and is validated as a
capability-advertisement identifier:

```python
    advertisement_id: str
...
        _require_identifier(self.advertisement_id, "capability-advertisement",
                            "advertisement_id")
```

`platform-model/schemas/capability-instance.schema.yaml` — moved from
`optional_fields` into `required_fields` with the reason stated normatively.

**No change to the admission path**: it already refused a body without one.

**Historical records are not silently normalised.** A stored instance that lost
the binding is refused on reload; `validator.py` catches the model's
`FabricError` and reports it as a finding, which is the released behaviour for a
model refusal — not a crash, and not a silent repair.

### GREEN

```
PASS: the instance schema requires advertisement_id
PASS: the instance schema no longer lists advertisement_id as optional
PASS: an instance whose advertisement_id is omitted entirely is refused
PASS: an instance whose advertisement_id is explicitly null is refused
PASS: an instance whose advertisement_id is empty is refused
PASS: an instance whose advertisement_id is outside the CADV grammar is refused
PASS: an instance whose advertisement_id is an identifier of another kind is refused
PASS: a valid instance carries the exact advertisement identity
PASS: the serialised instance names the advertisement
PASS: the identity survives a round trip through the model
PASS: an instance reloaded without its advertisement is refused
PASS: a lifecycle successor carries the advertisement identity forward
PASS: an admission naming a resolvable advertisement is accepted
PASS: the durable instance names the advertisement actually evaluated
PASS: an admission carrying no advertisement at all is refused / allocates nothing
PASS: an admission carrying an advertisement that does not resolve is refused / allocates nothing
PASS: an admission carrying a malformed advertisement identity is refused / allocates nothing
```

---

## 5. G11-A2 — effective target binding

### RED

```
REASON_TARGET_SCOPE exists                : False
admit_instance mentions permitted_targets : False
admit_instance checks permitted_capabilities : True
```

The composed scope was computed, its **capability** dimension checked and its
**classification** compared — and its **target** dimension proven non-empty and
then never read again.

### Root cause

`_effective_scope` refuses an empty intersection, which proves *some* machine is
authorised. It proves nothing about *this* one. With a single host in the fabric
the two are indistinguishable; with two, an instance could be admitted onto a
machine no grant authorised, and a `CapabilityInstance` is immutable.

### Implementation

`tools/fabric/admission.py`, immediately after the capability check:

```python
        if node not in effective["permitted_targets"]:
            _refuse(REFUSED, REASON_TARGET_SCOPE)
```

`node` is `host.get("node_identity_reference")`, already resolved earlier in
`admit_instance` and already used to bind the host trust subject
(`host_standing.subject_id != node`).

**The namespaces are not equated.** `CHOST-0001` is a fabric host record;
`HOST-0001` is the Platform Model node identity a trust grant's
`permitted_targets` is written in. The comparison is against the node identity,
because that is the identity the grant uses. Equating the two would invent a
mapping no accepted source declares — and the brief explicitly forbade it.

**A distinct reason, not a collapsed one.** `REASON_TARGET_SCOPE =
"target-not-permitted-by-scope"`, placed beside `REASON_CAPABILITY_SCOPE`, whose
existing comment already states the doctrine: *"Separate from an empty
intersection on purpose: nothing overlapped at all is a different fact from an
overlap that does not cover this binding, and an operator reading one as the
other looks in the wrong place."* The project distinguishes these semantics, so
this dimension is held to the same distinction.

### GREEN

```
PASS: a host whose node identity is a permitted target is admitted
PASS: the composed scope names the admitted machine
PASS: a host whose node identity is not a permitted target is refused
PASS: the refusal is named target-not-permitted-by-scope
PASS: an unauthorised target is not reported as an empty intersection
PASS: an unauthorised target allocates no instance
PASS: an unauthorised target advances no sequence
PASS: an empty target intersection is still reported as an empty scope
PASS: the target refusal is distinct from the empty-scope and capability reasons
```

The negative case is the demanding one: the composed scope names **two**
machines (`HOST-0001`, `HOST-0002`), so the intersection is non-empty and the
old code would have admitted. The host being admitted is `HOST-0002` while the
grant permits only `HOST-0001`, so the refusal is specifically about *this*
machine. A separate case proves a genuinely empty intersection still reports
`empty-effective-scope`.

---

## 6. G11-A3 — architecture derivation

### What committed authority already says

`_successors` (`admission.py`) states the doctrine in its own docstring:

> *"Immutability means nothing points forward, so the chain is read from what
> points back. Two records claiming one predecessor is a fork, reported rather
> than resolved: repairing it would pick a winner nobody chose."*
>
> *"A successor whose declared predecessor is absent does not become the head.
> It makes the chain unreadable, and a record at the end of a broken chain is
> not evidence that it is current — it is evidence that something is missing."*

Hosts and instances already use exactly this. G11-A3 reuses the same primitives
rather than writing a second chain algorithm that agrees until it does not.

### Advertisement chain semantics

```
CADV-000001          the first claim; supersedes nothing
     ↑
  supersedes         stated forward by the successor
     │
CADV-000002          the head: the record nothing supersedes
```

`advertisement_head(store, advertisement_id)` derives the head by reverse lookup
over `supersedes`, refusing rather than resolving a fork, a cycle, or a
successor whose predecessor is missing.

---

## 7. The `superseded_by` ruling

**Determination: `superseded_by` is intentionally derivable by reverse lookup.
It is retained, not written, and must not be corrected in G11-A.**

Evidence, all from committed source:

1. **No released operation writes it — for any of the seven record classes.**
   It appears on all seven models (`models.py:337, 379, 428, 482, 521, 574,
   623`) and nowhere as an assignment. Pinned by a test:
   `PASS: no released Fabric operation assigns superseded_by`.
2. **`supersedes` *is* written**, for hosts (`admission.py:1818`), instances
   (`1588`, `2068`) and routes (`1750`). Forward links are derived from it.
3. **`selection.py:296-298` already prefers the reverse lookup**
   (`record.get("supersedes") == current`) and only falls back to
   `superseded_by` if that finds nothing — a fallback that is dead on any store
   this platform wrote.
4. **`validator.py:243`** treats it as a reference to validate *if present*,
   never as one that must exist.

**Why it is not removed.** The brief said not to remove it casually if other
Fabric record classes depend on it. They do — `selection.py` reads it as a
compatibility fallback, and the validator validates it when present. Removing it
would be a seven-model, cross-module change with no correctness benefit, well
outside G11-A. It is **legacy structure that is safe to read and wrong to
write**, and writing one would be a second answer that can disagree with the
first.

**What G11-A does instead:** derives the head, never writes a backlink, and
proves the predecessor's bytes are untouched by an accepted renewal.

---

## 8. Renewal field-change policy

Determined from committed authority, not chosen silently.

| Field | May a renewal change it? | Authority |
|---|---|---|
| **capability host** | **No** — `renewal-of-another-host` | A claim is a self-report; another host's claim is not this one renewed |
| **package** | **No** — `renewal-changes-package` | `capability-instance.schema.yaml` `supersession_preserves` lists `capability_package_id`; a package change is a different binding |
| **contract** | **No**, transitively | A renewal names the same package; a package names one contract; the body's contract was already required to equal it |
| **satisfied contract versions** | **Yes**, within the package's declared set | The existing subset rule applies unchanged; nothing ties a renewal to its predecessor's subset |
| **resource profile** | **Yes**, still bounded by the host's verified profile | `satisfies(claim, verified)` applies unchanged |
| **validity window** | **Yes** — and must satisfy R13 | A renewal exists to carry a new window |

**A package or contract change is a new binding, not a renewal**, and is
enforced as such: it needs its own first advertisement rather than a link into
another binding's history.

### Two reasons removed as unreachable

**`renewal-changes-contract`** — a renewal must name the same package, a package
names exactly one contract, and `contract_id == package.contract_id` is already
enforced before any renewal rule runs. A contract change is refused as
`contract-not-of-package` and the renewal-specific reason could never be
produced. Pinned:
`PASS: no unreachable renewal-contract reason is carried in the vocabulary`.

**`renewal-supersedes-itself`** — discovered during recovery. The check was
`supersedes == identifier`, but `identifier` in `accept()` is the **request**
identity (`validate_request_id(request_id)`), not the record identity; the
record's identity is minted by `_commit` *after* every check has passed. So the
comparison was between two different namespaces and could never mean
self-supersession. A new claim cannot name itself — there is nothing to name
yet. A self-loop can only exist in a store damaged into holding one, and that is
a cycle the traversal already refuses. Pinned:
`PASS: an advertisement superseding itself is refused as advertisement-chain-cyclic`
and
`PASS: no unreachable self-supersession reason is carried in the vocabulary`.

**Both are the same defect the brief already identified in `superseded_by`:
vocabulary that documents a check the code cannot make.** Shipping them would
have added two more.

### The evidence category was corrected, not invented

The first draft invented `advertisement-renewal`. `evidence.py` has a **closed**
`REASON_CATEGORIES` tuple and a **symmetric** supersession rule
(`evidence.py:288-300`): a record naming a predecessor must declare a
superseding category, a record declaring one must name a predecessor, and the
predecessor must appear among the causal references. The released category for
exactly this is **`supersession`**, already used by hosts, instances and routes.
The implementation reuses it.

---

## 9. G11-A3 RED/GREEN matrix

### RED

```
register_advertisement accepts 'supersedes' : False
advertisement_head exists                   : False
schema optional_fields  : ['supersedes', 'superseded_by', 'notes']
```

### Implementation

- `advertisement_head(store, advertisement_id)` — head by reverse lookup, reusing
  `_successors` / `_head_of` with advertisement-shaped refusals.
- `register_advertisement(..., supersedes=None)` — syntax checked in
  `preflight()` (so a refusal spends no request identity), references and
  currency checked in `accept()`.
- Renewal rules: predecessor resolves; same host; same package; is the current
  head.
- Evidence category `supersession`, predecessor added to `causal_references`.
- `supersedes` added to the governed payload, so a renewal is a **different
  request** from a first claim with the same content.
- New reasons: `renewal-of-another-host`, `renewal-changes-package`,
  `renewal-predecessor-not-current`, `advertisement-chain-forked`,
  `advertisement-chain-cyclic`, `advertisement-chain-incoherent`.

### GREEN — acceptance and chain

```
PASS: the advertisement schema still offers supersedes
PASS: a first advertisement supersedes nothing
PASS: a renewal naming its predecessor is accepted
PASS: the renewal names the advertisement it replaces
PASS: the superseded advertisement is not given a backlink
PASS: the superseded advertisement is otherwise untouched
PASS: the head of the chain is the record nothing supersedes
PASS: the head of a head is itself
PASS: a sound chain resolves to a head
PASS: the renewal under test is accepted
PASS: an accepted renewal leaves the predecessor's bytes untouched
PASS: no released Fabric operation assigns superseded_by
PASS: CADV-000001 carries no superseded_by backlink
PASS: CADV-000002 carries no superseded_by backlink
```

`CADV-000002.supersedes == CADV-000001` is asserted directly, and the
predecessor's **file bytes** are compared before and after the accepted renewal.

### GREEN — every required negative control

| Control | Reason | Result |
|---|---|---|
| predecessor absent | `unresolved-reference` | PASS |
| malformed predecessor | `malformed-operation-content` | PASS |
| predecessor of another record kind | `malformed-operation-content` | PASS |
| self-supersession | `advertisement-chain-cyclic` | PASS |
| cycle of two | `advertisement-chain-cyclic` | PASS |
| fork (two records, one predecessor) | `advertisement-chain-forked` | PASS |
| successor whose predecessor is absent | `advertisement-chain-incoherent` | PASS |
| wrong host | `renewal-of-another-host` | PASS |
| package change | `renewal-changes-package` | PASS |
| contract mismatch (reachable path) | `contract-not-of-package` | PASS |
| stale successor | `invalid-validity-window` | PASS |
| predecessor already superseded / not current | `renewal-predecessor-not-current` | PASS |
| actor is not the subject | `actor-is-not-the-subject` | PASS |
| claim beyond verified profile | `resource-claim-not-verified` | PASS |

### Every refusal proves three things

Asserted as one sweep over six refusal shapes, so a refusal that quietly spent a
sequence position cannot hide behind a neighbour that did not:

```
PASS: a renewal with <shape> is refused
PASS: a renewal with <shape> writes nothing and spends no sequence
PASS: a renewal with <shape> leaves the predecessor byte-identical
```

The damaged-chain cases (cycle, fork, orphan) are constructed by rewriting a
fixture record in `/tmp` — states the released write path **cannot** produce,
which is precisely why the traversal must refuse rather than walk them.

---

## 10. Production compatibility

`CADV-000001` is readable under the corrected source with **no migration**:

```
read_record OK; supersedes = None   superseded_by = None
advertisement_head('CADV-000001') = CADV-000001
```

An absent `supersedes` means **first in chain**, and the record is its own head.
The production store validates under the corrected source with **zero
findings**:

```
$ python3 -m tools.fabric.cli validate --store-root /var/lib/kyri/fabric ...
  "findings": [],
  "counts": { "capability-advertisement": 1, "capability-instance": 0, ... }
```

---

## 11. Affected-surface review

Every construction and deserialisation of `CapabilityInstance`,
`CapabilityAdvertisement` and `register_advertisement`, and every reference to
`advertisement_id`, `supersedes` and `superseded_by`, was reviewed.

**Fixtures corrected because they genuinely conflicted with the new invariants —
never the invariants weakened:**

| Fixture | Conflict | Correction |
|---|---|---|
| `tests/test-fabric-runtime.sh` `instance()` | built a `CapabilityInstance` with no advertisement — a record no admission could produce | default `advertisement_id="CADV-000001"` |
| same suite, trust grants | `permitted_targets=("schmgmt.home.arpa",)` while the admitted host's node identity was `node/schai` — the grant authorised a machine that was not the one being admitted | targets name the machine the grant is about (6 occurrences) |
| `seeded_fabric_trust` | hardcoded one node while the selection matrices admit two | `permitted_targets=(node,) + tuple(nodes)` |
| `c6_world` | operator admission bound named one node while admitting onto two | bound names both, overriding only in that world rather than widening the shared `SCOPE` the identity matrices assert against |

Each was a fixture describing something the corrected platform would refuse.
Docs and reports referencing these fields were reviewed and needed no change.

---

## 12. Pre-existing unrelated failure — disclosed

The first full-validator run failed at step 48 of 92:

```
[48/92] Capability execution G5 ceremony
no ancestor within 40 commits carries the pinned operator package
```

**Not caused by this work.** The three G5 suites locate the pinned operator
package by walking back 40 commits and digesting `tools/__init__.py`,
`tools/capability`, `tools/common`, `tools/provisioning` at each. Proven:

- The digest **does not include `tools/fabric`**, which is all this checkpoint
  changed.
- `manifest_at` reads **git objects** (`git cat-file blob commit:file`), not the
  working tree, so uncommitted work cannot affect it at all.
- The pinned manifest matched an ancestor at **depth 43**, past the bound of 40.
  Four report commits since S5-A1 had pushed it out of range.

**Fix:** bound the walks to commits that **touched the digested paths**, which is
what "40 commits" always meant. Documentation commits no longer spend the
budget. The pinned ancestor now sits at filtered depth **8**. Applied to all
three affected suites (`g5-ceremony`, `g5-build-context`, `g5-authority`) and
committed **separately** so the integrity work stays reviewable.

This is the second checkpoint in a row to surface a stale-bound failure of this
shape; §17 asks whether ceremony checkpoints should run the validator.

---

## 13. Implementation commits

| # | SHA | Subject |
|---|---|---|
| 1 | `2d6d2a0ecdc9465ab5c364c7efe34f4ed45c8fc8` | `fix(tests): bound the G5 ancestor walks to packaged-tree commits` |
| 2 | `c35ccd8c9f260e3c26ae6a2033a1de3fc42f645e` | `fix(fabric): require advertisement identity on instances` |
| 3 | `305f84aaeb6ee7fa960aaeb0ef60670f5f0fbcb2` | `feat(fabric): enforce effective target and govern advertisement supersession` |

### Changed files

```
commit 1  tests/test-capability-execution-g5-authority.sh
          tests/test-capability-execution-g5-build-context.sh
          tests/test-capability-execution-g5-ceremony.sh

commit 2  platform-model/schemas/capability-instance.schema.yaml   |  9 +-
          tests/test-fabric-runtime.sh                             | 25 +-
          tools/fabric/models.py                                   | 10 +-

commit 3  tests/test-fabric-g11-integrity.sh                       | 707 ++++++ (new)
          tools/dev/run-validation.sh                              | 10 +-
          tools/fabric/admission.py                                | 121 +-
```

### Why A2 and A3 share a commit

The brief preferred three commits and forbade manufacturing separation by
destructively rewriting the interrupted tree. **A1 was cleanly separable by
file** and is its own commit. **A2 and A3 are not**: both live in
`tools/fabric/admission.py` in interleaved regions, and the new suite asserts
all three as one matrix. Splitting them would have required partial staging of a
file the interruption had already touched, and would have produced commits that
individually fail the validator — an A2-only commit still carries the A3 test
assertions, and vice versa. The safest coherent grouping was used, as the brief
permits, and the commit message states both corrections separately.

---

## 14. Validation

All run from the clean implementation commit `305f84aa…`, worktree clean:

| Check | Result |
|---|---|
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — ShellCheck 0.9.0, exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh` | **PASS (full mode) — 92/92 steps** |
| `tests/test-fabric-g11-integrity.sh` | **PASS** — 91 assertions, 0 failures |
| `tests/test-fabric-runtime.sh` | **PASS** — full suite |

```
Validation passed (full mode), started 2026-08-26T17:05:34-05:00, 92/92 steps.
```

The new suite is registered as step 47 and the total rose 91 → 92.

---

## 15. Production before / after

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric | `7780dacf…ab072` | `7780dacf…ab072` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifact | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |

```
CADV-000001  cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195  UNCHANGED
CADV count = 1        CADV-000002 : ABSENT
CINST = 0             capability-instance.seq : absent
CROUTE = 0            CSEL = 0
Root Authority /mnt/kyri-root : unmounted
```

Every fixture in the new suite works in a temporary root, and the suite asserts
the production Fabric and Trust stores are unchanged when it finishes:
`PASS: the production Fabric and Trust stores are unchanged`.

---

## 16. Execution-readiness ledger

| # | Finding | Status |
|---|---|---|
| 1 | `CapabilityInstance.advertisement_id` must be non-optional | **CLOSED** — commit `c35ccd8c…` |
| 2 | `admit_instance` must require the admitted host in `effective_scope["permitted_targets"]` | **CLOSED** — commit `305f84aa…` |
| 3 | Installed Capability runtime lacks `tools.fabric` dependency closure | **ACTIVE — G11-B** |
| 4 | G11 should package the existing `tools.fabric` unless dependency inspection disproves it | **ACTIVE — G11-B** |
| 5 | `select` needs genuine read-only preflight before `CSEL-000001` | **ACTIVE — G11-C** |
| 6 | Advertisement admission-time stale/future-window defect | **CLOSED** in S5-B1, commit `90597fe9…` |
| 7 | Advertisement renewal/supersession required before `CADV-000002` | **CLOSED** — commit `305f84aa…` |

**Neither G11-B nor G11-C was implemented**, as instructed.

New, recorded for the reviewer:

- **`superseded_by` is legacy derived structure** (§7). Read by `selection.py` as
  a fallback and validated when present; written by nothing. Not corrected here.
- **Two unreachable reasons were removed** (§8), the same defect class as the
  `superseded_by` finding.

---

## 17. Generation classification and G11 install surface

| Object | Classification |
|---|---|
| `tools/fabric/admission.py` | **repository-only** — not installed by any generation |
| `tools/fabric/models.py` | **repository-only** |
| `platform-model/schemas/capability-instance.schema.yaml` | **declarative schema**, repository-only |
| `tests/test-fabric-g11-integrity.sh` | **test**, repository-only |
| `tests/test-fabric-runtime.sh`, the three G5 suites | **tests**, repository-only |
| `tools/dev/run-validation.sh` | **developer tooling**, repository-only |

**Nothing installed changed. Generation 11 was not installed.**

Established mechanically in S5-B1 and unchanged: no
`provisioning/execution/install-generation-*.sh` names any `tools/fabric` object,
and the installed library root `/usr/lib/kyri/python/tools/` holds only
`capability`, `common` and `__init__.py`.

### Objects G11 will eventually need to deploy

If the reviewer accepts blocker 4 — packaging the existing `tools.fabric`
dependency rather than duplicating Fabric logic — the install surface must add
the `tools/fabric` package, because the installed
`tools/capability/fabric_evidence.py` and `tools/capability/coordinator.py`
already import it:

```
tools/fabric/__init__.py        tools/fabric/identifiers.py
tools/fabric/admission.py       tools/fabric/models.py
tools/fabric/eligibility.py     tools/fabric/resources.py
tools/fabric/errors.py          tools/fabric/selection.py
tools/fabric/evidence.py        tools/fabric/store.py
tools/fabric/trust_adapter.py   tools/fabric/validator.py
tools/fabric/cli.py             tools/fabric/inspection.py
```

**Both corrections in this checkpoint land in `admission.py` and `models.py`**,
so a G11 that installs `tools/fabric` carries them in. Dependency-closure
inspection is G11-B's work and was not performed here.

---

## 18. Actions explicitly NOT performed

- **No `CADV-000002` created.** Absent; production `CADV` count remains 1.
- **No `CINST-000001` created.** Count 0; `capability-instance.seq` absent.
- **No CROUTE, no CSEL.**
- **`CADV-000001` not touched** — byte-identical, not migrated, timestamps not
  rewritten, and its expiry not raced.
- **No production mutation of any kind.** Every fixture ran in a temporary root.
- **`superseded_by` not written**, anywhere, for any record class — and not
  removed from the models either (§7).
- **Nothing staged. Nothing invoked. Trust, artifact authority and Platform
  Evidence untouched. Root Authority not mounted.**
- **G11-B and G11-C not implemented. Generation 11 not installed.**
- **No work discarded, reset, stashed, or blindly repeated** after the
  interruption (§2).
- **No invariant weakened to preserve a stale fixture.**
- **No secrets recorded.**

---

## 19. Recommended next checkpoint

**G11-B — installed Capability Runtime dependency closure.**

With blockers 1, 2, 6 and 7 closed, the remaining barriers to CINST are the
installed-generation ones. G11-B should:

1. Inspect the dependency closure of the installed Capability runtime and
   confirm whether packaging `tools.fabric` is an architectural layering
   violation or the correct fix (blockers 3 and 4).
2. Produce the exact install manifest delta, using §17's list as the starting
   surface.
3. Not install anything — Generation 11 installation stays a separate,
   independently authorised ceremony.

Then **G11-C** (`select` preflight), and only then a CINST checkpoint.

**Sequencing note.** `CADV-000001` lapses at `2026-08-27T14:13:53-05:00`. Nothing
breaks when it does — it stays a durable historical record and stops satisfying
ELIG-6, exactly as `on_stale: instance-ineligible` specifies. A future CINST will
need a fresh advertisement, and the renewal path now exists to produce one as
`CADV-000002 supersedes CADV-000001` under a new request identity. **That is a
production ceremony for a later checkpoint, not part of G11-B.**

---

## 20. Questions requiring reviewer ruling

1. **Is the A2/A3 commit grouping acceptable?** (§13.) A1 is separate; A2 and A3
   share one file and one test matrix, and splitting them would have produced
   commits that individually fail the validator.
2. **Confirm the `superseded_by` ruling** (§7): retained as legacy derived
   structure, read by `selection.py` as a fallback, written by nothing. The
   alternative is a cross-cutting removal across seven models, outside G11-A.
3. **Are the two removed reasons agreed?** (§8.) `renewal-changes-contract` and
   `renewal-supersedes-itself` were unreachable. Removing them is the same
   judgement that produced the `superseded_by` finding.
4. **Are the runtime fixture corrections accepted?** (§11.) Trust grants now
   name the machine they are about, which is what production does
   (`HOST-0001` targeting `HOST-0001`), but it changes six fixture values.
5. **Should ceremony checkpoints run the full validator?** Two consecutive
   checkpoints have now surfaced stale-bound failures that no ceremony would
   have caught (§12, and S5-B1 §12).
6. **May a renewal change `satisfied_contract_versions` and the resource
   profile?** (§8.) Committed authority permits both within the existing bounds,
   and G11-A did not restrict them further. Confirm that is intended.

---

## Appendix A — commands executed

```bash
# Interruption recovery audit
git status --short ; git diff --check ; git diff --stat
python3 -c "<ast.parse admission.py, models.py; load_strict both schemas>"
bash -n tests/test-fabric-g11-integrity.sh
python3 -c "<import admission; confirm every symbol the interrupted work added>"
bash tests/test-fabric-g11-integrity.sh          # first run, before any change

# RED evidence
python3 -c "<model field type/default; schema required vs optional>"
python3 -c "<REASON_TARGET_SCOPE absent; permitted_targets unread in admit_instance>"
python3 -c "<supersedes not accepted; advertisement_head absent>"

# Architecture derivation
grep -n superseded_by tools/fabric/*.py
grep -n 'reason_category="supersession"' tools/fabric/admission.py
sed -n '40,80p' tools/fabric/evidence.py         # REASON_CATEGORIES, SUPERSEDING_CATEGORIES
sed -n '630,650p' tools/fabric/admission.py      # _successors doctrine

# Pre-existing G5 drift, proven independent
python3/git -c "<manifest_at over 454 commits; pinned ancestor at depth 43>"
git rev-list --max-count=40 HEAD -- "${MANIFEST_PATHS[@]}"   # filtered depth 8

# Production compatibility
python3 -c "<read CADV-000001; advertisement_head == itself>"
python3 -m tools.fabric.cli validate --store-root /var/lib/kyri/fabric ...

# Validation, from the clean implementation commit
git diff --check ; tools/dev/run-shellcheck.sh
pre-commit run --all-files ; tools/dev/run-validation.sh   # 92/92
```

## Appendix B — the three invariants, stated once

```
A1  Every admitted CapabilityInstance names the advertisement it was
    admitted against.
        model + schema require it; admission always did.
        A record that lost it is refused on reload, not repaired.

A2  host.node_identity_reference ∈ effective_scope["permitted_targets"]
        checked at admit_instance, against the node identity a grant is
        written in -- never against the fabric host record identity.
        → target-not-permitted-by-scope, distinct from empty-effective-scope.

A3  A renewal is a new advertisement that states which claim it replaces.
        same host, same package, same contract (transitively), predecessor
        must be the current head.
        The predecessor is read and never written: the head is derived by
        reverse lookup over `supersedes`, and no superseded_by is assigned.
        → CADV-000002.supersedes == CADV-000001, CADV-000001 byte-identical.
```
