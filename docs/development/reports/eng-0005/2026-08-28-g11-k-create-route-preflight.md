# ENG-0005 G11-K — create-route Preflight Coverage and Rehearsal Integrity

**Date:** 2026-08-28
**Checkpoint:** G11-K
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Add permanent end-to-end preflight coverage for `create-route`
before the first production route write. Determine first whether the released
rehearsal path is correct; RED-first only if there is a defect.

**Outcome: ACCEPTED.**

**The released `create-route --preflight` is correct on its first-ever
exercise.** It reaches `preflight`, predicts the identity, mutates nothing, and
refuses for the same reasons the write refuses. **No source change was made and
none was needed** — this checkpoint adds coverage, not a correction, and did not
manufacture an implementation change to justify itself.

- **69 assertions** now pin the CLI preflight end to end, preflight/write
  equivalence, and every refusal `create_route` can produce (§6–8).
- **Coverage moves 5/11 → 6/11** write operations (§10).
- A **genuine read-only production preflight is feasible** without publishing
  operator input, proven against the live stores (§9).
- Full validator **96/96**; production byte-identical.

**Three things were nearly assumed wrong, and are now pinned:**

1. **The route identifier is four digits — `CROUTE-0001`, not `CROUTE-000001`**
   (§4). My own G11-J report and the checkpoint brief both used the six-digit
   form. Routes share the narrow width with `CAPDEF`/`CCON`/`CPKG`/`CHOST`;
   only `CADV`/`CINST`/`CSEL` are six.
2. **`create_route` does not require its predecessor to be the chain head**, so
   two successors of one route are both accepted and *selection* is what refuses
   the resulting fork (§11).
3. **`create_route` accepts a route naming a binding that has been withdrawn**
   (§12) — contradicting its own docstring. The system still fails closed:
   selection excludes the candidate as `instance-not-admitted`. Reported for a
   ruling; **not patched**, because repairing governed behaviour inside a
   coverage checkpoint is exactly what the source policy forbids.

---

## 2. Starting authority

| Gate | Observed | |
|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD at start | `5c6476c4bab8798d66e1f6085c87709ebc1ac4c1` | PASS |
| Worktree | clean | PASS |
| G11-J report ancestor of HEAD | yes | PASS |
| CROUTE count | **0** | PASS |
| `capability-route.seq` | **absent** | PASS |
| CSEL count | **0** | PASS |
| Trust store | `valid: true`, `problems: []` | PASS |
| Installed runtime | 57 objects, 9-file closure | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   4d95072bf3cc3553c61654a382ae85aca52b851f35c2fd83b0169bf069a02ccf
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

**Clock state, informational only** (the reviewer ruled: do not race
`CADV-000002`):

```
CADV-000002  valid_until    2026-08-29T09:24:51-05:00   18h 39m   FRESH
CINST-000001 admitted_until 2026-08-29T13:46:27-05:00   23h 00m   VALID
```

Neither was renewed, and nothing in this checkpoint depended on either.

---

## 3. `create-route`, reconstructed from source

| Question | Answer, from source |
|---|---|
| **Operation** | `create_route(store, *, ...)` — **no `trust_store` parameter** |
| **CLI verb** | `create-route`; `WRITE_OPERATIONS["create-route"] = ("create_route", False)`, `CREATED_KINDS["create-route"] = "capability-route"`; **not** in `NEEDS_EVIDENCE` |
| **Required body** | `request_id`, `actor`, `approving_authority`, `recorded_at`, `capability_id`, `contract_id`, `accepted_contract_versions`, `locality`, `candidate_instances`, `data_classification`, `route_version`, `provenance` |
| **Optional** | `description`, `overlap_starts_at`/`overlap_ends_at`, `supersedes`, `notes` |
| **Actor / approving authority** | `_human_authority` — both non-empty text. **There is no `_no_self_governance` call**: routes have no self-governance rule, because a route names bindings rather than admitting a subject |
| **Trust** | **Not consumed.** Trust was spent once, at admission; the route routes to a binding that already carries it |
| **Expiry** | **None.** No `valid_until`, no validity window. `overlap_window` is a cutover assertion, not route validity |
| **Currentness** | By supersession chain only, plus a strictly increasing `route_version` |
| **Advertisement** | **Never referenced** — zero occurrences of `capability-advertisement` in `create_route`. Freshness enters only at selection, via ELIG-6 |
| **Allocation boundary** | `_commit` — construction proof against a probe identity, then allocate, then write; a rehearsal stops before allocation |
| **Replay / conflict** | `exact-replay` returns the original identity; a changed body under one `request_id` is `conflict` / `request_identity_conflict` |
| **Relation to selection** | `_resolve_route` matches capability, contract, accepted version set, classification and locality; **no route → no candidate**. Two current routes for one class is `route-ambiguous-for-request-class`, refused rather than resolved |

### Candidate rules

> *"A route targets admitted bindings only: targeting an advertisement would
> mean routing to a self-report, and targeting a withdrawn binding would mean
> routing to a decision somebody already reversed."*

Each named candidate must resolve, match the route's capability **and**
contract, be a **binding root** (`_binding_root(records, candidate) ==
candidate`), and carry `lifecycle_state == "admitted"`. §12 examines whether the
second half of that docstring sentence is actually enforced.

### Vocabularies

```
LOCALITIES                     ('local-only', 'operator-controlled-only', 'any-trusted')
WORKLOAD_DATA_CLASSIFICATIONS  ('internal',)
route_version                  int >= 1, strictly increasing across a chain
```

**A caution for the ceremony:** `CHOST-0001.location_class` is `on-premises`,
which belongs to a **different vocabulary** than the route's `locality`. They
are not interchangeable.

---

## 4. The route identifier is four digits

From `tools/fabric/identifiers.py`:

```python
CAPABILITY_DEFINITION_ID     = re.compile(r"^CAPDEF-[0-9]{4}$")
CAPABILITY_CONTRACT_ID       = re.compile(r"^CCON-[0-9]{4}$")
CAPABILITY_PACKAGE_ID        = re.compile(r"^CPKG-[0-9]{4}$")
CAPABILITY_HOST_ID           = re.compile(r"^CHOST-[0-9]{4}$")
CAPABILITY_ROUTE_ID          = re.compile(r"^CROUTE-[0-9]{4}$")     # <- four
CAPABILITY_ADVERTISEMENT_ID  = re.compile(r"^CADV-[0-9]{6}$")
CAPABILITY_INSTANCE_ID       = re.compile(r"^CINST-[0-9]{6}$")
CAPABILITY_SELECTION_ID      = re.compile(r"^CSEL-[0-9]{6}$")
```

and the store agrees: `capability-route` carries `width=4`.

**The next route identity is `CROUTE-0001`.** My G11-J report and the G11-K
brief both wrote `CROUTE-000001`; that identity could not be constructed. The
operator input filename follows the identity, so the ceremony destination will
be **`/etc/kyri/fabric/croute-0001.json`**, not `croute-000001.json`.

Pinned by two assertions so it cannot drift back.

---

## 5. The coverage gap, proven mechanically

The audit counts an operation as covered only when a `--preflight` invocation or
a `rehearsing()` block **actually drives that operation** — not when the
operation merely appears in a suite that preflights something else. The method
handles helper indirection: `test-fabric-preflight.sh` names its operation once
inside a `run()` helper, far from every call site, which a naive window scan
misses (that is precisely how G11-H's original figure went wrong).

**Before this checkpoint:**

```
COVERED   declare-capability       test-fabric-preflight.sh (cli)
COVERED   declare-contract         test-fabric-runtime.sh (rehearsing)
COVERED   declare-package          test-fabric-package-manifest.sh (rehearsing)
COVERED   admit-subject            test-fabric-preflight.sh (cli),
                                   test-fabric-host-admission.sh (rehearsing),
                                   test-fabric-evidence-authority.sh (rehearsing)
COVERED   admit-instance           test-fabric-instance-admission-integrity.sh (cli)
UNCOVERED register-advertisement
UNCOVERED create-route
UNCOVERED withdraw-subject
UNCOVERED refresh-subject
UNCOVERED withdraw-instance
UNCOVERED retire-instance

covered 5/11    uncovered 6/11
```

This **confirms the accepted G11-J count of 6 of 11 uncovered**, by an
independent run of the audit. No further correction was needed.

---

## 6. First released preflight — no defect

The first time anything has ever driven `create-route --preflight`, against a
copy of the production lineage:

```json
{
  "destination": "…/capability-routes/CROUTE-0001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "create-route",
  "outcome": "preflight",
  "predicted_record_id": "CROUTE-0001",
  "record_kind": "capability-route",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "would_accept": true
}
```

**exit 0**, and the fixture held zero routes with `capability-route.seq` still
absent afterwards.

**There is no RED for the rehearsal path.** The brief anticipated a possible
defect of the R15 shape — `admit_instance` carried a post-commit guard that
compared two absences under rehearsal — and `create_route` has no such guard.
Its `_commit` is the last statement in `accept()`, with nothing evaluated after
it, so a rehearsal simply stops there.

Per the source policy, **no implementation change was manufactured.** What
follows is coverage.

---

## 7. Preflight / write equivalence

```
PASS: an in-process rehearsal reaches preflight (preflight/None)
PASS: the rehearsal names no record
PASS:   -> in-process rehearsal: no route written, capability-route.seq absent
PASS: the same body is accepted when written
PASS: the written identity is the predicted one (CROUTE-0001)
PASS: the rehearsal and the write share one request digest
PASS: the stored route names the rehearsed capability and contract
PASS: the stored route carries the rehearsed candidate list, in order
PASS: the stored route carries the rehearsed version, locality and classification
PASS: a first route is filed as route-change
PASS: a first route declares no overlap window
PASS: a first route supersedes nothing
```

One predicted identity, one request digest, and a stored record whose semantics
match what the rehearsal reported.

---

## 8. Negative controls

Every refusal `create_route` can produce, in the released vocabulary, each
proven to leave `capability-route.seq` absent:

| Control | Outcome / reason |
|---|---|
| unknown candidate instance | `not-found / unresolved-reference` |
| malformed candidate identifier | `invalid / malformed-operation-content` |
| empty candidate list | `refused / no-declared-candidate` |
| duplicated candidate | `refused / duplicate-candidate` |
| empty accepted version set | `refused / versions-not-declared` |
| unknown locality | `invalid / unknown-locality` |
| unknown data classification | `invalid / unknown-data-classification` |
| `route_version` zero | `refused / invalid-route-version` |
| non-integer `route_version` | `invalid / invalid-route-version` |
| contract not of the capability | `refused / contract-not-of-capability` |
| candidate is a lifecycle successor | `refused / candidate-not-a-binding-root` |
| unknown superseded route | `not-found / unresolved-reference` |
| successor version not increasing | `refused / invalid-route-version` |
| successor for a different request class | `refused / supersedes-different-subject` |
| overlap window without supersession | `refused / overlap-window-without-supersession` |
| half-declared overlap window | `invalid / malformed-overlap-window` |
| overlap that adds nothing | `refused / overlap-window-without-cutover` |
| overlap that carries nothing forward | `refused / overlap-window-without-coexistence` |
| identical replay | `exact-replay` → original identity |
| same `request_id`, changed body | `conflict / request_identity_conflict` |
| valid cutover (carries one, adds one) | **accepted** |

Five of my initial expectations were wrong and were corrected against observed
behaviour — `unknown-locality` and `unknown-data-classification` refuse as
`INVALID` rather than `REFUSED`, `duplicate-candidate` the other way round, and
the withdrawn-binding case is §12. **No governed behaviour was changed for any
of them.**

---

## 9. Production preflight feasibility

**Yes — and proven, not argued.** A scratch, explicitly non-authoritative body
was preflighted against the **live** Fabric store from an isolated approved
directory:

```bash
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file route.json --approved-directory <isolated scratch directory>
```

```
outcome preflight | would_accept true | mutated false
predicted_record_id CROUTE-0001 | destination_exists false | rehearsal_reason null
exit 0
```

```
fabric content identical  : YES
fabric metadata identical : YES   (per-path size, mtime, mode)
CROUTE count              : 0
capability-route.seq      : absent
/etc/kyri/fabric croute   : 0 files
```

`create-route` needs no trust store and no Evidence arguments, so the CLI
requires only `--store-root`, `--expected-uid`, `--expected-gid`,
`--input-file`, `--approved-directory`. Containment is enforced against the
directory the operator names, so an isolated preparation directory applies the
same rule to a tighter root — the pattern G11-F established.

**Nothing was published to `/etc/kyri/fabric`, and the ceremony candidate was
not created.** The request digest above belongs to a throwaway probe body and
is deliberately not carried forward.

---

## 10. Corrected coverage inventory

**After this checkpoint:**

```
COVERED   declare-capability
COVERED   declare-contract
COVERED   declare-package
COVERED   admit-subject
COVERED   admit-instance
COVERED   create-route              <- added here
UNCOVERED register-advertisement
UNCOVERED withdraw-subject
UNCOVERED refresh-subject
UNCOVERED withdraw-instance
UNCOVERED retire-instance

covered 6/11    uncovered 5/11
```

As the brief anticipated. The remaining five are **not** fixed here.

`register-advertisement` is the notable one: G11-F ran a successful production
preflight of it, but no permanent test drives it. Working once in production and
being permanently tested are different properties, and only the second survives
a future change.

---

## 11. Observed: a route predecessor need not be the chain head

`create_route`'s supersession block checks that the predecessor resolves, that
it names the same capability and contract, and that `route_version` strictly
increases. **It never asks whether the predecessor is still the chain head.**

Consequence, measured:

```
PASS: two successors of one route are both accepted: head-ness is not checked
PASS: selection refuses to read a forked route chain rather than picking a winner
      (_Refusal: route-chain-unreadable)
```

A monotonic `route_version` does not prevent a fork — v2 and v3 can both
supersede v1. `selection._chain_heads` then refuses the whole traversal as
`route-chain-unreadable` rather than choosing a winner, which is fail-closed but
disables selection for **every** route, not just the forked chain.

**This is the same shape as R16**, where admission checked advertisement
freshness but not head-ness. It is recorded as observed behaviour and pinned by
tests; **no change was made**, and §14 asks for a ruling.

---

## 12. Observed: a withdrawn binding can still be routed to

The finding that most warrants a ruling, and the one my initial test expectation
got wrong.

**What happens.** `withdraw_instance` is a lifecycle decision: it writes a
**successor** record carrying `lifecycle_state: withdrawn` and
`supersedes: <root>`. Records are immutable, so the binding **root** keeps
`lifecycle_state: admitted` forever.

`create_route` reads `instance.get("lifecycle_state")` on the **named** record.
For a binding root that is permanently `"admitted"`, and `_binding_root` returns
the root itself — so both candidate rules pass:

```
PASS: the withdrawal is a successor record; the binding root stays 'admitted'
PASS: OBSERVED: create_route accepts a route naming a WITHDRAWN binding's root
      (accepted/None)
```

That contradicts the operation's own docstring — *"targeting a withdrawn
binding would mean routing to a decision somebody already reversed."*

**The system still fails closed.** Selection resolves the binding's current
lifecycle state and refuses:

```
PASS: selection selects nothing from a route naming a withdrawn binding
PASS: and excludes it as instance-not-admitted
```

So the guarantee holds; it is enforced one plane later than the docstring
implies. **Both halves are pinned by tests**, so the compensating control cannot
disappear unnoticed.

**Not patched.** The source policy is explicit — *"Do not combine another
governed-behavior correction with the CINST ceremony"*, and the same reasoning
applies to a coverage checkpoint. §14 asks for the ruling.

---

## 13. Changed files, classification, and validation

| File | In the installed G11 nine-file closure? |
|---|---|
| `tests/test-fabric-route-preflight.sh` (new) | no — test |
| `tools/dev/run-validation.sh` | no |
| `.github/workflows/ci.yml` | no |

**Zero files under `tools/fabric/` changed**, and no source changed at all. The
installed closure is `__init__`, `errors`, `identifiers`, `models`,
`request_identity`, `evidence`, `store`, `validator`, `inspection` — untouched.

**`G11_RUNTIME_REINSTALL_REQUIRED = NO`.**

### Validation, from the clean implementation commit `3ca8f1e`

| Check | Result |
|---|---|
| `tests/test-fabric-route-preflight.sh` | **PASS — 69 assertions** |
| `tests/test-fabric-instance-admission-integrity.sh` | **PASS** |
| `tests/test-fabric-runtime.sh`, `test-fabric-g11-integrity.sh`, `test-capability-fabric.sh` | **PASS** (via the full validator) |
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh --quick` | **PASS — 74/74** |
| `tools/dev/run-validation.sh` | **PASS (full) — 96/96** |

```
Validation passed (full mode), started 2026-08-28T14:38:52-05:00, 96/96 steps.
```

The full total moved 95 → 96 for the new suite and was **re-measured in both
modes**; quick is unchanged at 74 because the suite registers in the full-only
branch.

**One static-assertion failure was hit and fixed in the suite, not the
checker.** `test-docs-static.sh` forbids a test line matching a
create-verb near a production path, and my header sentence *"Nothing here
touches /var/lib/kyri"* matched because **`touch`es** contains `touch`. The
prose was reworded. The rule is right; my sentence was unlucky.

---

## 14. Findings requiring a reviewer ruling

1. **A withdrawn binding can be routed to** (§12). `create_route` reads the
   named record's frozen `lifecycle_state` rather than the binding's current
   state, so its own docstring guarantee is not enforced at route-creation time.
   Selection compensates (`instance-not-admitted`). Options: enforce the
   lifecycle head in `create_route` (the R16 shape), or accept the division of
   responsibility and correct the docstring. **Not decided here.**
2. **A route predecessor need not be the chain head** (§11). A fork is creatable
   and disables selection for all routes via `route-chain-unreadable`. Options:
   require head-ness in `create_route`, or accept it. **Not decided here.**

Both would be governed-behaviour changes and belong in their own checkpoint with
their own RED, exactly as R15/R16 did.

---

## 15. Production non-mutation

| Authority | Before | After | |
|---|---|---|---|
| Fabric | `4d95072bf3cc3553c61654a382ae85aca52b851f35c2fd83b0169bf069a02ccf` | same | **BYTE-IDENTICAL** |
| Trust | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | same | **BYTE-IDENTICAL** |
| Artifact | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | same | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | same | **BYTE-IDENTICAL** |
| Installed runtime | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | same | **BYTE-IDENTICAL** |
| `CINST-000001` | `92eba1c35bf96d23bb0a86ad52a0fe3b944e5f1b89611ffa0e9ff35152a1e729` | same | **UNCHANGED** |

`diff` of the before and after captures: **identical**.

```
CROUTE = 0    capability-route.seq : absent
CSEL   = 0    CINST = 1    CADV = 2
installed runtime : 57 objects
Root Authority    : unmounted
```

Every fixture runs in a temporary root, and the suite asserts the production
Fabric and Trust stores are unchanged as its own final check. **No privileged
operation; every command ran as uid 1000.**

---

## 16. Actions NOT performed

- **`CROUTE-0001` not created**, and no ceremony candidate prepared or frozen.
- **`/etc/kyri/fabric/croute-0001.json` not published.**
- **No CSEL created. No CADV or CINST renewed** — the reviewer ruled not to race
  `CADV-000002`, and neither clock was touched.
- **No source change.** The two findings in §14 were documented, not patched.
- **No package staged, no capability invoked.**
- **Trust, Artifact and Platform Evidence not mutated.**
- **Generation 11 not reinstalled**; installed runtime byte-identical.
- **Root Authority not mounted.**
- **The other five uncovered preflight paths not fixed** (§10).
- **Approved-directory containment not weakened.**
- **No privileged operation, no `sudo`.**
- **No secrets recorded.**

---

## 17. Recommendation for the `CROUTE-0001` ceremony

`create-route` is now preflight-covered, and a production preflight is proven
feasible. **The route ceremony is unblocked**, subject to the two rulings in
§14 — neither of which blocks a *first* route naming a currently-admitted
binding, since both concern superseded or withdrawn states this lineage does not
yet have.

Recommended shape, on the G11-I pattern:

1. **Derive the body** from committed authority: `capability_id CAPDEF-0001`,
   `contract_id CCON-0001`, `accepted_contract_versions ["1.0.0"]`,
   `candidate_instances ["CINST-000001"]`, `data_classification "internal"`,
   `route_version 1`, and a `locality` chosen from
   `('local-only', 'operator-controlled-only', 'any-trusted')` — **decided
   deliberately**, since `local-only` requires exact node-identity equality at
   selection and `any-trusted` does not.
2. **Rehearse** in a fixture; prove preflight/write equivalence.
3. **Production preflight** from an isolated directory; expect
   `would_accept: true` and `predicted_record_id: CROUTE-0001`.
4. **Freeze** `/etc/kyri/fabric/croute-0001.json` at `root:cschott 0640` —
   **note the four-digit filename** (§4).
5. **Re-preflight from `/etc/kyri/fabric`**, then write under separate
   authorisation.

**The advertisement clock does not gate this.** `create_route` never reads an
advertisement (§3), so `CADV-000002`'s expiry at `2026-08-29T09:24:51-05:00`
does not constrain the route ceremony. It gates **`CSEL-000001`** only — and on
current timing a `CADV-000003` + `CINST-000002` renewal before selection remains
the likely path, as G11-J set out.

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo` at any point.**

```bash
# Phase 0
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor 5c6476c HEAD
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# Phase 1 — create_route, from source
sed -n '1789,1935p' tools/fabric/admission.py
grep -n '"create-route"' tools/fabric/cli.py           # needs_trust False
sed -n '<class CapabilityRoute>' tools/fabric/models.py
sed -n '<_resolve_route|_chain_heads>' tools/fabric/selection.py
grep -n 'CROUTE' tools/fabric/identifiers.py           # four digits
python3 -c "<store id_prefixes / id_widths>"

# Phase 2 — mechanical coverage audit
python3 -c "<per-operation: does a --preflight invocation or rehearsing()
             block actually drive it, allowing for helper indirection>"

# Phase 3 — first ever create-route --preflight, against a production COPY
python3 -m tools.fabric.cli create-route --preflight --store-root <copy> ...

# Phases 4-5 — the permanent suite
bash tests/test-fabric-route-preflight.sh              # 69 assertions

# the withdrawn-binding finding, isolated
python3 <probe: admit -> withdraw -> create_route -> select_candidate>
<read the CSEL record's excluded_candidates>           # instance-not-admitted

# Phase 6 — production preflight feasibility, read-only, scratch body
python3 -m tools.fabric.cli create-route --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file route.json --approved-directory <isolated scratch dir>
<fabric content AND metadata digests before/after>

# Phase 8 — validation from the clean implementation commit
git diff --check ; tools/dev/run-shellcheck.sh ; pre-commit run --all-files
tools/dev/run-validation.sh --quick    # 74/74
tools/dev/run-validation.sh            # 96/96
```

## Appendix B — create-route, stated once

```
create_route(store, ...)          NO trust_store. NO advertisement. NO expiry.
        │
        ├── structure     actor + approving_authority named
        │                 locality in LOCALITIES
        │                 data_classification in WORKLOAD_DATA_CLASSIFICATIONS
        │                 route_version int >= 1
        │                 candidates: non-empty, unique, well-formed
        │                 overlap window: both ends or neither, and only
        │                                 alongside a supersession
        │
        ├── references    capability, contract; contract must be the capability's
        │
        ├── supersession  predecessor resolves
        │                 same capability AND contract
        │                 route_version strictly increases
        │                 ...but NOT that the predecessor is the head   <- §11
        │
        ├── candidates    each resolves, matches capability + contract,
        │                 is a binding ROOT, and its OWN record says "admitted"
        │                 ...which a withdrawn binding's root always does  <- §12
        │
        └── commit        evidence reason_category route-change | supersession
                          allocate CROUTE-000N (FOUR digits), write

Selection is where a route becomes consequential:
    no route            -> no candidate
    two current routes  -> route-ambiguous-for-request-class
    forked chain        -> route-chain-unreadable
    withdrawn candidate -> instance-not-admitted, excluded
```
