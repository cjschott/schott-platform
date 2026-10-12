# ENG-0005 G11-N — register-advertisement Preflight Coverage and CADV-000003 Renewal Semantics

**Date:** 2026-08-28
**Checkpoint:** G11-N
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Before preparing `CADV-000003`, permanently prove the released
`register-advertisement` rehearsal path; then derive the exact renewal
semantics, the next identity, and the validity-window authority.

**Outcome: ACCEPTED.**

**The released `register-advertisement --preflight` is correct in both shapes
that matter**, including the shape that was broken in `admit_instance` (R15). No
defect, so **no source change was manufactured** — coverage only.

- **74 assertions** now pin both rehearsal shapes end to end through the
  released CLI, preflight/write equivalence, determinism, and every refusal the
  operation can produce (§4).
- **Coverage moves 6/11 → 7/11**, derived mechanically (§5).
- **`CADV-000003`** is the predicted next identity, read-only (§7).
- All eight renewal-semantics questions answered from source (§6).
- Full validator **97/97**; focused suite run twice with identical results.
- **Production byte-identical**, content, metadata and per-path structure (§9).

**Two findings carried to the reviewer:**

1. **The 24-hour window is ceremony ruling, not architecture** (§6, Q1–Q3).
   Source constrains only *ordering*; there is no minimum, no maximum, and no
   default anywhere. `CADV-000003`'s duration therefore needs an explicit
   ruling, not an inherited assumption.
2. **The route-renewal answer is B** (§8): `CROUTE-0001` **cannot** represent a
   renewed binding chain. `CROUTE-0002` will be required. The supporting source
   is exact, and the reachability of the G11-K route-head gap is analysed
   honestly (§8.3).

---

## 2. Starting authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | same | PASS |
| HEAD | `ed7e5cca05b6e299b88185a256cf59a6cc6be33a` | same | PASS |
| Origin contains HEAD | yes | `origin/arch/eng-0005-execution-transition` | PASS |
| Worktree | clean, nothing staged, nothing untracked | clean | PASS |
| G11-M report present and ancestor | yes | yes | PASS |
| Fabric (released `inspect_records`) | valid | `status: reported`, no defects | PASS |
| Trust | valid | `valid: true`, `problems: []` | PASS |
| Installed Generation 11 | accepted state | 57 objects, 9-file closure, `CGEN-000000000001` | PASS |
| Root Authority | unmounted | unmounted | PASS |
| CADV / CINST / CROUTE / CSEL | 2 / 1 / 1 / 0 | same | PASS |
| `capability-advertisement.seq` | 2 | 2 | PASS |

```
Fabric   f75dd8e68d74d19065070d08edd8f0781532fca93101eaf176bbdc046185f503
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

**Clocks at start** — recorded, and raced by nothing:

```
CADV-000002  valid_until     2026-08-29T09:24:51-05:00   17h 32m   FRESH
CINST-000001 admitted_until  2026-08-29T13:46:27-05:00   21h 54m   VALID
```

---

## 3. The reconstructed `register-advertisement` contract

| Aspect | From source |
|---|---|
| Operation | `register_advertisement(store, *, ...)` — **no `trust_store` parameter** |
| CLI verb | `register-advertisement` → `("register_advertisement", False)`; `CREATED_KINDS → capability-advertisement`; **not** in `NEEDS_EVIDENCE` |
| Identifier | `^CADV-[0-9]{6}$`, store width **6** |
| Required | `request_id`, `actor`, `recorded_at`, `capability_host_id`, `capability_package_id`, `contract_id`, `satisfied_contract_versions`, `advertised_resource_profile`, `observed_at`, `valid_until`, `provenance` |
| Optional | `supersedes`; `approving_authority` **must be absent** — supplying one refuses `unexpected-approving-authority`, because recording an approver would make a self-report into an approval |
| Actor | must equal `capability_host_id` — a host may advertise only itself (`actor-is-not-the-subject`) |
| Windows | `valid_until > observed_at`, **and** `observed_at <= recorded_at < valid_until` — judged against the body's own `recorded_at`, never a clock |
| Host currency | the host declaration must be the chain head (`host-record-superseded`) |
| Relationships | package names the contract (`contract-not-of-package`); versions declared by the package (`versions-not-declared`); the host's **verified** profile must satisfy the claim (`resource-claim-not-verified`) |
| Renewal | R1 predecessor resolves · R2 same host · R3 same package · R4 predecessor is the chain head |
| Trust | **none consumed** — zero references |
| Allocation boundary | `_commit`: construction proof against a probe identity, then allocate, then write; a rehearsal stops before allocation |
| Replay / conflict | `exact-replay` returns the original identity; changed body under one `request_id` → `conflict` / `request_identity_conflict` |
| Digest route | `LEGACY_DIGEST` — noted, not a defect |

### Structural reachability, checked mechanically

```
in WRITE_OPERATIONS : True ('register_advertisement', False)
in CREATED_KINDS    : True capability-advertisement
in NEEDS_EVIDENCE   : False
--help exposes --preflight : yes
-> command_preflight reachable: True
```

**Reachable is not covered.** The audit in §5 treats them separately, because
G11-K's original figure went wrong by conflating them.

---

## 4. First genuine rehearsal, and the R15 shape

RED-first discipline: the rehearsal was run **before** any test was written.

### Successor shape — against a copy of the production lineage

```
outcome preflight | would_accept true | rehearsal_reason null
predicted_record_id CADV-000003 | mutated false | exit 0
fixture CADV count after: 2   seq: 2
```

### First-advertisement shape — the one that mattered

This is the shape R15 broke in `admit_instance`: there, a post-commit guard
compared the unallocated identity against an absent predecessor, so
`None == None` refused **every** first-admission preflight.

```
advertisements before: 0
predicted:             CADV-000001
FIRST-advertisement rehearsal (supersedes absent):
    outcome=preflight  reason=None
    seq exists after rehearsal: False   advertisements: 0
identical body WRITTEN: accepted, CADV-000001
    digests agree: True
```

**No RED. No defect.** And the reason is structural, not luck:

```
register_advertisement:  return _commit(store, "capability-advertisement", ...)
                         ^ returned directly; nothing evaluated afterwards

admit_instance:          kind, allocated = _commit(...)
                         if allocated == supersedes or ...: _refuse(...)
                         ^ assigned, then evaluated -- which is where R15 lived
```

`register_advertisement` **cannot** carry the R15 shape because it has no
post-commit code at all. **The permanent suite asserts this structurally**, so a
future edit introducing a post-commit guard would have to confront the test
rather than quietly reintroduce the defect.

**No implementation correction was manufactured**, per the brief.

---

## 5. Permanent coverage

`tests/test-fabric-advertisement-preflight.sh` — **74 assertions**,
fixture-only, registered in local validation and CI.

### Coverage matrix — all nineteen required points

| # | Required | Covered by |
|---|---|---|
| 1 | first-advertisement rehearsal | in-process **and** CLI, predicted `CADV-000001` |
| 2 | successor rehearsal | in-process **and** CLI, predicted `CADV-000002` |
| 3 | predicted identity | asserted in both shapes and against the write |
| 4 | zero allocation during rehearsal | record count checked after every rehearsal |
| 5 | zero sequence advancement | `capability-advertisement.seq` absence/value checked |
| 6 | no write | record count checked |
| 7 | rehearsal digest == write digest | both shapes |
| 8 | predicted ID == written ID | both shapes |
| 9 | replay | `exact-replay` returns the original identity |
| 10 | request-identity conflict | `conflict` / `request_identity_conflict` |
| 11 | malformed / invalid content | `malformed-operation-content`, `unexpected-approving-authority`, `versions-not-declared` |
| 12 | unresolved references | unknown host, unknown package → `unresolved-reference` |
| 13 | supersession errors | R1–R4, plus a cyclic chain |
| 14 | time / window validation | all three window rules |
| 15 | lifecycle / current-head | `host-record-superseded`; `renewal-predecessor-not-current` |
| 16 | package / contract / host relationships | `contract-not-of-package`, `actor-is-not-the-subject`, `resource-claim-not-verified` |
| 17 | repeated rehearsal deterministic | two rehearsals over an unchanged store agree, allocating nothing |
| 18 | no Trust mutation | Trust tree hashed before and after a rehearsal |
| 19 | production authorities byte-identical | suite epilogue asserts both stores |

Two behaviours are pinned deliberately because they are easy to assume wrong:

- **An expired predecessor may still be lawfully superseded.** Freshness gates
  *consumption*, not *supersession* — the G11-F ruling, which until now had no
  test.
- **A damaged advertisement chain refuses** as `advertisement-chain-cyclic`
  through the governed traversal, rather than being repaired.

### Corrected 11-operation inventory, derived mechanically

**Before:**

```
COVERED   declare-capability, declare-contract, declare-package,
          admit-subject, admit-instance, create-route            6/11
UNCOVERED register-advertisement, withdraw-subject, refresh-subject,
          withdraw-instance, retire-instance                     5/11
```

**After:**

```
COVERED   declare-capability       test-fabric-preflight.sh (cli)
COVERED   declare-contract         test-fabric-runtime.sh (rehearsing)
COVERED   declare-package          test-fabric-package-manifest.sh (rehearsing)
COVERED   admit-subject            test-fabric-preflight.sh (cli) + 2 more
COVERED   register-advertisement   test-fabric-advertisement-preflight.sh (cli, rehearsing)
COVERED   admit-instance           test-fabric-instance-admission-integrity.sh (cli)
COVERED   create-route             test-fabric-route-preflight.sh (cli)
UNCOVERED withdraw-subject
UNCOVERED refresh-subject
UNCOVERED withdraw-instance
UNCOVERED retire-instance

covered 7/11    uncovered 4/11
```

The four remaining are all **lifecycle** operations, none of which has been used
in production yet. They are not fixed here.

---

## 6. `CADV-000003` renewal semantics

Answered from source, in the order the brief asks.

### Q1 — What rule governed `CADV-000002`'s `valid_until`?

`observed_at + exactly 24 hours`, applied in G11-F under the **explicit
reviewer/operator ruling** recorded in S5-B2A §"Advertisement duration — exactly
24 hours". `CADV-000002` carries `observed_at 2026-08-28T09:24:51-05:00` and
`valid_until 2026-08-29T09:24:51-05:00` — a 24-hour delta.

### Q2 — Fixed by architecture, or ceremony precedent?

**Ceremony precedent and ruling, not architecture.** The only constraints source
imposes are *ordering*:

```python
if valid_until <= observed_at:              _refuse(REFUSED, REASON_WINDOW)
if not observed_at <= recorded_at < valid_until:  _refuse(REFUSED, REASON_WINDOW)
```

The schema declares `valid_until` required and states the ordering rule; it
declares **no duration** at all. Nothing in source would refuse an hour, a week,
or a year.

**`CADV-000003`'s duration therefore requires an explicit ruling.** It should
not be inherited by assumption from `CADV-000002`, and this report does not
choose one.

### Q3 — Is there a maximum duration?

**No.** No maximum, no minimum, no default appears in `tools/fabric/` or in the
advertisement schema. Searched explicitly.

### Q4 — Is overlap between predecessor and successor permitted or required?

**Neither — the concept does not exist for advertisements.**
`register_advertisement` contains **zero** references to overlap, and the
advertisement schema has no overlap field. (`overlap_window` exists on
**routes**, for cutover; it is a different record kind and a different question.)

Supersession is instantaneous in the lineage sense: the head moves when the
successor is written. Whether the predecessor's window has closed is a separate,
unconnected fact.

### Q5 — Must the successor supersede the current head?

**Yes.** Rule R4:

```python
if advertisement_head(store, supersedes) != supersedes:
    _refuse(REFUSED, REASON_RENEWAL_NOT_HEAD)     # renewal-predecessor-not-current
```

`CADV-000002` is confirmed the current head (§7), so it is the only lawful
predecessor.

### Q6 — Can a successor be created after the predecessor expires?

**Yes.** No renewal rule reads the predecessor's `valid_until`;
`advertisement-not-fresh` is enforced only in the *consumption* paths
(`admit_instance` and C5 eligibility). This is the G11-F ruling, and it now has
a permanent test (§5). It is also necessary rather than merely permitted: if
expiry barred supersession, a lapsed advertisement could never be renewed.

### Q7 — Does renewal require any Trust evaluation?

**No.** `register_advertisement` takes no `trust_store` and contains zero Trust
references. An advertisement is a self-report that grants nothing.

### Q8 — Does it alter CINST state automatically?

**No.** `register_advertisement` contains **zero** references to
`capability-instance`. `CINST-000001` will continue to name `CADV-000002`
permanently — records are immutable, and the instance is bound to the
advertisement that admitted it (G11-A1). Publishing `CADV-000003` does **not**
rescue `CINST-000001` from ELIG-6 staleness; only a new admission against the
new advertisement does. §8 turns on exactly this.

### Field disposition for the eventual `CADV-000003` body

| Field | Disposition |
|---|---|
| `capability_host_id`, `capability_package_id`, `contract_id` | **copied unchanged** — R2/R3 require the same host and package, and the contract is the package's |
| `actor` | **copied unchanged** (`CHOST-0001`) — must equal the host |
| `satisfied_contract_versions` | **copied unchanged** (`["1.0.0"]`) — must be declared by the package |
| `advertised_resource_profile` | **copied unchanged** (`{architecture: x86-64}`) — must be satisfied by the host's verified profile |
| `recorded_at`, `observed_at`, `valid_until` | **newly timestamped** — window duration **awaiting ruling** (Q2) |
| `supersedes` | **`CADV-000002`** — supersession link, the head |
| `request_id` | **new**, per ceremony convention |
| `provenance.recorded_at` | **new date**; `class`/`source` copied |
| `approving_authority` | **deliberately absent** — supplying one refuses |

**The permanent body is not authored here**, because Q2 is unresolved.

---

## 7. Read-only production prediction

```
peek_next_id(capability-advertisement)  ->  CADV-000003
advertisement_head(CADV-000002)         ->  CADV-000002     (current head)
advertisement_head(CADV-000001)         ->  CADV-000002

prediction mutated fabric : NO
capability-advertisement.seq still: 2
```

### Scratch production preflight — explicitly non-authoritative

Run only after the permanent coverage passed, with a throwaway body:

```json
{
  "outcome": "preflight",
  "would_accept": true,
  "rehearsal_reason": null,
  "predicted_record_id": "CADV-000003",
  "destination_exists": false,
  "mutated": false,
  "request_digest": "sha256:0082d3b3…825fef",
  "request_id": "g11n-scratch-feasibility-probe-not-authoritative"
}
```

```
fabric content identical  : YES
fabric metadata identical : YES
CADV count 2   seq 2   /etc/kyri/fabric cadv-000003: 0 files
```

**This is not the ceremony body.** Its `request_id` says so, its window duration
is unruled, and its digest is deliberately not carried forward. What it
establishes is that a genuine production preflight of the renewal is feasible
read-only, from an isolated directory, publishing nothing.

---

## 8. Route renewal — answer **B**

> **After `CADV-000003` and `CINST-000002 supersedes CINST-000001`, can
> `CROUTE-0001` — whose candidate list contains the binding root `CINST-000001`
> — still legally/selectably represent that binding chain?**

## **B. `CROUTE-0002` is required to name the renewed binding.**

### 8.1 Why, from exact source

**A supersession starts a new binding; it does not continue the old one.**

`tools/fabric/admission.py`:

```python
LIFECYCLE_CATEGORIES = ("withdrawal", "retirement")     # line 246
```

```python
def _binding_root(records, identifier):
    """A lifecycle decision continues a binding; a declared supersession starts
    a new one. Which happened is read from the evidence category the record
    already carries."""
    ...
    if evidence.get("reason_category") not in LIFECYCLE_CATEGORIES:
        return identifier
```

`admit_instance` files a supersession as `reason_category="supersession"`, which
is **not** in `LIFECYCLE_CATEGORIES`. Therefore
`_binding_root(CINST-000002) == CINST-000002` — **`CINST-000002` is its own
binding root**, a different binding from `CINST-000001`.

**Selection reads the named candidate, and does not walk forward for
instances.** `tools/fabric/selection.py:543`:

```python
instance = _referenced(store, "capability-instance", candidate)
```

The only forward walk in selection is `_host_of` (line 283), and it applies to
**hosts** only — *"The machine as it stands now, not as the binding first named
it."* No equivalent exists for instances.

So `CROUTE-0001` would continue to name `CINST-000001`, and selection would
evaluate `CINST-000001` — which names `CADV-000002` permanently and becomes
ineligible under ELIG-6 once that advertisement lapses. `CINST-000002` would be
eligible but is **not in the route's candidate list**, and routes are immutable.

**`CROUTE-0001` cannot represent the renewed chain. A new route is required.**

### 8.2 Consequence for `CROUTE-0002`

`CROUTE-0002` must name `CINST-000002`, carry `route_version 2`, and supersede
`CROUTE-0001`. All of this is within released semantics — G11-K exercised a
valid cutover in fixtures, including the overlap-window rules.

### 8.3 Does this exercise the G11-K route-head gap?

**Reported honestly rather than assumed.** The gap is that `create_route` does
not require its predecessor to be the chain head, so a **fork** is creatable.

Production currently holds **exactly one route**, so `CROUTE-0001` is
necessarily the chain head, and a well-formed `CROUTE-0002 supersedes
CROUTE-0001` therefore **cannot** exercise the gap — the predecessor *is* the
head. The gap becomes reachable only with two or more routes in a chain and an
attempt to supersede a non-head one.

**Per the brief's instruction, route-head hardening is flagged as a mandatory
checkpoint before any `CROUTE-0002` production ceremony.** The reachability
analysis above is supplied so the reviewer can rule with the facts: this is a
precaution against a gap that a correct `CROUTE-0002` would not reach, not the
closing of a live exposure. If the reviewer prefers, hardening could equally
follow `CROUTE-0002` — but that is their call, and this checkpoint does not make
it.

**Nothing about route behaviour was changed here.**

---

## 9. Production no-mutation

| Authority | Before | After | |
|---|---|---|---|
| Fabric | `f75dd8e68d74d19065070d08edd8f0781532fca93101eaf176bbdc046185f503` | same | **IDENTICAL** |
| Trust | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | same | **IDENTICAL** |
| Artifact | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | same | **IDENTICAL** |
| Platform Evidence | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | same | **IDENTICAL** |
| Installed runtime | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | same | **IDENTICAL** |

Per-path structural manifest, before vs after: **no structural change**.

```
CADV = 2   CINST = 1   CROUTE = 1   CSEL = 0
capability-advertisement.seq = 2    capability-route.seq = 1
Root Authority : unmounted
```

**No production write. No privileged operation; every command ran as uid 1000.**

---

## 10. Verification

| Check | Result |
|---|---|
| `tests/test-fabric-advertisement-preflight.sh` | **PASS — 74 assertions** |
| the same suite, run a second time | **PASS — 74 assertions, byte-identical result list** |
| `tests/test-fabric-route-preflight.sh` | PASS (via validator) |
| `tests/test-fabric-instance-admission-integrity.sh` | PASS (via validator) |
| `tests/test-fabric-runtime.sh`, `test-capability-fabric.sh`, platform-model backstop | PASS (via validator) |
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh` | **PASS (full) — 97/97** |

```
Validation passed (full mode), started 2026-08-28T15:57:04-05:00, 97/97 steps.
```

The full total moved 96 → 97 for the new suite; quick mode is unchanged at 74
because the suite registers in the full-only branch.

---

## 11. Is the `CADV-000003` body ready to freeze?

**No — one ruling is missing.**

Everything except the window duration is unambiguous and derivable (§6). What is
not settled is **how long `CADV-000003` should be valid**, because source
imposes no duration and the 24-hour figure is a ceremony ruling that was made
for the *bootstrap* advertisement (S5-B2A) and reapplied in G11-F.

Reapplying 24 hours by habit would be exactly the kind of silent inheritance the
programme has avoided elsewhere. Options for the reviewer:

- **24 hours again**, matching precedent — simple, and keeps the renewal cadence
  visible;
- **a longer window**, reducing renewal churn now that the chain is established;
- **a window chosen to cover the remaining ceremony sequence** (`CINST-000002`,
  `CROUTE-0002`, `CSEL-000001`) with margin, since each consumes freshness at
  its own instant.

Once ruled, the body is a mechanical assembly of §6's field disposition, and the
G11-L pattern applies: derive, rehearse, production-preflight, freeze, write.

---

## 12. Remaining blockers

1. **`CADV-000003` window duration** — needs an explicit ruling (§11). This is
   the only thing standing between here and a G11-L-shaped preparation
   checkpoint.
2. **Route-head hardening before `CROUTE-0002`** — flagged mandatory per the
   brief; §8.3 supplies the reachability analysis for an informed ruling.
3. **Withdrawn-binding route admission** (G11-K) — still deferred, still
   unpatched, still compensated by selection.
4. **Four uncovered preflight paths** — `withdraw-subject`, `refresh-subject`,
   `withdraw-instance`, `retire-instance`. All lifecycle operations, none used
   in production yet.
5. **The clock**, unchanged in character: `CADV-000002` lapses
   `2026-08-29T09:24:51-05:00`, after which `CINST-000001` is permanently
   ineligible and the renewal chain is the only path to a selection.

---

## 13. Actions NOT performed

- **No `CADV-000003` created**, and no operator input frozen for one.
- **No `CINST-000002`, no `CROUTE-0002`, no `CSEL-000001`.**
- **Nothing withdrawn or retired.**
- **Route-head enforcement not patched; withdrawn-binding routing not patched.**
- **No implementation change to `register_advertisement`** — none was needed,
  and none was manufactured (§4).
- **Trust, Artifact and Platform Evidence not mutated.**
- **Runtime not reinstalled; sudoers untouched; Root Authority not mounted.**
- **No package staged, nothing invoked.**
- **ENG-0006 not begun; no TrustGateway cutover.**
- **Neither clock raced or renewed.**
- **No privileged operation, no `sudo`.**
- **No secrets recorded.**

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo`.**

```bash
# Mandatory preflight
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
git branch -r --contains ed7e5cc ; git merge-base --is-ancestor ed7e5cc HEAD
python3 -c "<inspect_records, read-only>"
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )

# Part A — the contract, and reachability
grep -n '"register-advertisement"' tools/fabric/cli.py
sed -n '<register_advertisement>' tools/fabric/admission.py
python3 -c "<WRITE_OPERATIONS / CREATED_KINDS / NEEDS_EVIDENCE membership>"

# First genuine rehearsal, BEFORE writing any test
python3 -m tools.fabric.cli register-advertisement --preflight ...   # successor
python3 <probe-first-adv.py>                                        # first advertisement
python3 -c "<no post-commit code after return _commit>"

# Part B — permanent coverage
bash tests/test-fabric-advertisement-preflight.sh                    # 74 assertions, twice
python3 -c "<mechanical per-operation coverage audit>"               # 6/11 -> 7/11

# Part C — renewal semantics
grep -rniE 'max.*(duration|validity)|MAX_VALID' tools/fabric/ platform-model/schemas/...
<overlap / capability-instance / trust reference counts in register_advertisement>

# Part D — prediction and scratch preflight
python3 -c "<peek_next_id, advertisement_head>"
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric ... --approved-directory <isolated scratch>

# Part E — route renewal
python3 -c "<LIFECYCLE_CATEGORIES>" ; sed -n '<_binding_root>' tools/fabric/admission.py
grep -n 'capability-instance' tools/fabric/selection.py

# Verification
git diff --check ; tools/dev/run-shellcheck.sh ; pre-commit run --all-files
tools/dev/run-validation.sh            # 97/97
```

## Appendix B — the renewal question, stated once

```
TODAY
    CADV-000002  head, fresh until 2026-08-29T09:24:51-05:00
         ↓ admitted against
    CINST-000001 binding root, admitted, names CADV-000002 PERMANENTLY
         ↓ named by
    CROUTE-0001  candidates [CINST-000001]

AFTER RENEWAL
    CADV-000003 supersedes CADV-000002        <- lawful even if 000002 expired
         ↓ admitted against
    CINST-000002 supersedes CINST-000001
         reason_category = "supersession"
         NOT in LIFECYCLE_CATEGORIES ("withdrawal","retirement")
         -> _binding_root(CINST-000002) == CINST-000002
         -> a NEW binding, not a continuation

    CROUTE-0001  still names CINST-000001
         selection reads the NAMED candidate (selection.py:543);
         no forward walk exists for instances -- only for hosts (_host_of)
         CINST-000001 names CADV-000002, which is stale
         -> ELIG-6 unmet -> nothing selected

    => B. CROUTE-0002 is required, naming CINST-000002, version 2,
          superseding CROUTE-0001.

    The G11-K route-head gap needs a NON-head predecessor to bite.
    With one route, CROUTE-0001 is necessarily the head, so a correct
    CROUTE-0002 would not reach it. Hardening is flagged mandatory per
    the brief; the reachability fact is supplied so the ruling is informed.
```
