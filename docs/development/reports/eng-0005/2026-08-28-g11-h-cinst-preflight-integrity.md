# ENG-0005 G11-H — CINST Preflight Integrity and Advertisement Head Enforcement

**Date:** 2026-08-28
**Checkpoint:** G11-H
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Implement the two source corrections the reviewer ruled on in
response to the G11-G STOP: make a first instance admission rehearsable (R15),
and require the consumed advertisement to be the current head (R16). RED first.
Create no CINST, freeze no operator input, create no advertisement.

**Outcome: ACCEPTED.**

Both corrections are implemented, both RED conditions are inverted, and the test
gap that hid them is closed by a permanent suite of **38 assertions** that drives
`admit-instance --preflight` end to end through the released CLI and pins all
four advertisement states to their own outcome.

- **R15** — the minted-identity guard is **scoped, not removed**. It now runs
  only when an identity was actually allocated. Three independent proofs that
  the write path is untouched (§7).
- **R16** — admission now requires
  `advertisement_head(store, advertisement_id) == advertisement_id`, read
  through the **existing** governed traversal, so forked, cyclic and unreadable
  chains keep failing closed exactly as they do for renewal (§10).
- **New refusal reason** `advertisement-record-superseded`, named after the
  host counterpart already used in this same operation (§9).
- **`admission.py` is on the `GENERATION_11_EXCLUDED` list and is absent from
  the installed runtime**, so no generation is opened and **no reinstall is
  required** (§13).
- Full validator **95/95** from the clean implementation commit; production
  byte-identical throughout.

**Two pre-existing defects were found and corrected in their own commits** (§12).
Both are stale-bound test assertions that began failing when the operator
installed Generation 11 in G11-E — neither caused by, nor related to, R15/R16.
One of them had rendered a negative control **vacuous**, which is the worse of
the two: a control that cannot fail is a line of output, not a test.

`CINST-000001` was **not** created. `CADV-000002` remains fresh with **20h 23m**
left at report time (§15).

---

## 2. Reviewer rulings implemented

| | Ruling | Disposition |
|---|---|---|
| **R15** | The freshly allocated identity may be compared against supersession identities **only when an identity was actually allocated**. The write-path safety check must remain intact. | **Implemented** (§6–7) |
| **R16** | A CINST admission must consume the current advertisement head; freshness and head-ness are independent and both mandatory. Renewal semantics unchanged. | **Implemented** (§8–11) |
| **R17** | Bootstrap admission duration: `admitted_at = evaluated_at`, `admitted_until = admitted_at + 24h`, as explicit policy — **not** a schema default, and **no** `admitted_until <= advertisement.valid_until` coupling. | **Noted, nothing encoded** (§16) |
| **R18** | `admission_decision_id` for CINST-000001 is `eng-0005-cinst-000001-admission`; not a TDEC; no global grammar created here. | **Noted, nothing encoded** (§16) |

R17 and R18 govern the *body* of the next ceremony, not source. This checkpoint
deliberately encodes neither — R17 explicitly warns against silently encoding a
global automatic duration, and R18 against inventing a grammar. **No default,
no coupling and no token was added to any source file.**

---

## 3. Starting authority

| Gate | Observed | |
|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD at start | `0c76297df400a156dd8ea65b19a93bbcc1043322` | PASS |
| Worktree | clean | PASS |
| G11-A…G ancestors of HEAD | all ten commits YES | PASS |
| Installed runtime | 57 objects, 9-file Fabric closure | PASS |
| CADV / CINST / CROUTE / CSEL | 2 / 0 / 0 / 0 | PASS |
| `capability-instance.seq` | absent | PASS |
| Trust store | `valid: true` | PASS |
| Root Authority | unmounted | PASS |
| **`CADV-000002`** | **FRESH**, 21h 5m remaining at start | PASS |

```
Fabric   6428520119fd10e5bcd6f4dd0b3bb99f6fc6181dc5bcfd7f27e8131798219a30
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

`CADV-000002`'s freshness is recorded because the brief asked for it. **It did
not influence either correction** — both are about what admission checks, not
about when.

---

## 4. R15 — the exact RED

Captured against released source before any change:

```
RED A (R15) — preflight of a FIRST admission refuses
  rehearsal (supersedes absent) : outcome=refused reason=supersedes-different-capability
  digest                        : sha256:ad1094ba…fca259f
  RED-A1 refuses as supersedes-different-capability : True
  identical body WRITTEN        : outcome=accepted record_id=CINST-000001
  digest                        : sha256:ad1094ba…fca259f
  RED-A2 write is accepted                          : True
  RED-A3 refused rehearsal and write share a digest  : True
  rehearsal WITH supersedes     : outcome=preflight reason=None
  RED-A4 a superseding rehearsal already works       : True
```

**RED-A3 is the one that proves it is a defect and not a disagreement about the
body.** The refused rehearsal and the accepted write carry the *same* request
digest — the refusal happens after identification, so the two are provably the
same request answered two different ways.

**RED-A4 is the isolating control.** Same code path, same store, differing only
in whether `supersedes` is `None`.

---

## 5. Root cause

```python
kind, allocated = _commit(store, "capability-instance", evidence, ...)
# C1 allocates from a sequence that never reuses a value, so a fresh
# identity cannot be the identity it supersedes.
if allocated == supersedes or (prior_root is not None and allocated == prior_root):
    _refuse(REFUSED, REASON_SUPERSEDES_CAPABILITY)
```

and, in `_commit`:

```python
_constructed(kind, PROBE_IDS[kind], evidence, build)
if _REHEARSING.get():
    return kind, None
```

For a **first** admission `supersedes` is `None`. Under `rehearsing()`
`allocated` is `None`. `None == None` is `True`.

The guard exists to prove a freshly minted identity is not the one it
supersedes. **Under a rehearsal nothing is minted, so there is nothing for it to
check — and it compared two absences instead.** Reachable only when `supersedes`
is absent, which is every first admission, and therefore `CINST-000001` exactly.

---

## 6. R15 — implementation

`tools/fabric/admission.py`:

```python
        # C1 allocates from a sequence that never reuses a value, so a fresh
        # identity cannot be the identity it supersedes.
        #
        # Guarded on an identity having actually been allocated. A rehearsal
        # stops before allocation and `_commit` reports that as `None`; for a
        # first admission `supersedes` is `None` too, and comparing the two
        # absences refused every preflight of the one operation that most needs
        # one. The check belongs to the committed write, where both operands are
        # real identities -- there is nothing for it to say about an identity
        # that was deliberately not minted.
        if allocated is not None and (
                allocated == supersedes
                or (prior_root is not None and allocated == prior_root)):
            _refuse(REFUSED, REASON_SUPERSEDES_CAPABILITY)
```

One added term. Nothing removed, no refusal reason retired, no supersession rule
relaxed.

---

## 7. R15 — the minted-identity guard is preserved, proven three ways

The ruling says the write-path safety check must remain intact and the guard
must not simply be deleted. Three independent proofs, all permanent assertions
in the new suite.

### 7.1 The verdict is unchanged for every write-path case

On the write path `allocated` is always a minted identity — a non-empty string —
so the added `is not None` term is always true and the condition reduces to what
it was. Enumerated over the reachable domain:

| `allocated` | `supersedes` | `prior_root` | before | after | same |
|---|---|---|---|---|---|
| `CINST-000002` | `CINST-000001` | `None` | False | False | ✓ |
| `CINST-000001` | `CINST-000001` | `None` | **True** | **True** | ✓ |
| `CINST-000003` | `CINST-000002` | `CINST-000001` | False | False | ✓ |
| `CINST-000001` | `CINST-000002` | `CINST-000001` | **True** | **True** | ✓ |

```
PASS: for every write-path case the guard's verdict is unchanged by the scoping
```

### 7.2 C1 cannot produce the collision — the guard is a backstop

`FabricStore._next_after` *"skips occupied names"*, and both `allocate_id` and
`peek_next_id` route through it. Rewinding the sequence to `0` on a store that
already holds `CINST-000001` still yields `CINST-000002`:

```
PASS: with the sequence rewound C1 still refuses to re-mint an occupied identity
```

So the guard's precondition is unreachable through the released allocator. It is
a backstop against a damaged one — which is exactly what its own comment says.

### 7.3 And it still fires when that damage is simulated

The only way to reach the precondition is to damage the allocator, so that is
what the test does:

```python
class DamagedStore(FabricStore):
    def allocate_id(self, kind):
        if kind == "capability-instance":
            return "CINST-000001"
        ...
```

```
PASS: a damaged allocator that re-mints the superseded identity still refuses
      (got refused/supersedes-different-capability)
```

**The guard still executes, still fires, and still gives the same reason.**

---

## 8. R16 — the exact RED

```
RED B (R16) — a fresh but SUPERSEDED advertisement is admitted
  CADV-000001 valid_until        : 2026-08-31T00:00:00-05:00
  fresh at evaluated_at          : True
  advertisement_head(CADV-000001): CADV-000002   (so CADV-000001 is NOT head)
  admission against it           : outcome=accepted reason=None
  RED-B a fresh but superseded advertisement is ADMITTED : True
```

Constructed by pushing the superseded predecessor's `valid_until` forward, so
**freshness cannot be what excludes it** — the only remaining difference is
head-ness, and released admission did not look.

`advertisement_head` existed and was called from exactly one place —
`register_advertisement`'s renewal rule, at the *other* end of the chain. The
consumer never asked.

Left unfixed, an instance would have been permanently bound to a claim the host
had already replaced, and every eligibility answer about that binding would rest
on it. `CapabilityInstance` is immutable, so the binding could not have been
repointed.

---

## 9. Refusal vocabulary — the ruling, and how it was made

The brief required inspecting existing vocabulary first, reusing an accurate
reason if one exists, and documenting any addition.

**Surveyed:**

| Existing reason | Why it does not fit |
|---|---|
| `advertisement-not-fresh` | temporal. Reporting a fresh record as stale is the specific confusion the ruling forbids. |
| `renewal-predecessor-not-current` | renewal-specific, and this is not a renewal. |
| `instance-not-current-head` | about the instance being acted on, not a referenced advertisement. |
| `host-record-superseded` | **the exact analogue** — same operation, same situation: a referenced record that is not its chain head. |

**Added:** `REASON_ADVERT_SUPERSEDED = "advertisement-record-superseded"`,
following `host-record-superseded` in shape and meaning, with the reasoning
recorded at the definition:

> *Freshness is temporal and supersession is lineage: an advertisement can be
> well inside its window and still not be what this host currently claims.
> Reporting the second as the first would send an operator to renew a claim that
> does not need renewing, when what they must do is consume the head.*

The two reasons name two different operator remedies: `advertisement-not-fresh`
means **renew**; `advertisement-record-superseded` means **consume the head**.

---

## 10. R16 — implementation

Placed with the other checks that ask whether the advertisement describes *this*
binding, and before the clocks:

```python
        # And it must be what the host claims *now*. Freshness and currentness
        # are independent: a superseded advertisement can still be well inside
        # its window, and admitting against it would bind this instance to a
        # claim the host has already replaced -- so an eligibility answer about
        # the binding would rest on a claim that is no longer the host's.
        #
        # Read through the same governed traversal the renewal rule uses, so a
        # forked, cyclic or unreadable advertisement chain fails closed here
        # exactly as it does there, rather than through a second lineage walk
        # that could disagree with the first.
        #
        # Ordered before the clocks deliberately. An advertisement that is both
        # superseded and expired is reported as superseded, because that is the
        # actionable fact: the operator consumes the head, which is fresh, and
        # renewing the record they named would not help.
        if advertisement_head(store, advertisement_id) != advertisement_id:
            _refuse(REFUSED, REASON_ADVERT_SUPERSEDED)
```

**No second traversal.** The suite asserts both halves of that structurally:

```
PASS: there is exactly one advertisement lineage traversal
PASS: instance admission consumes that traversal rather than reimplementing it
```

**Renewal semantics are untouched.** `register_advertisement` was not modified.

### The ordering decision, stated

An advertisement that is both superseded *and* expired now reports
`advertisement-record-superseded`. The ruling required only that the two named
cases not be conflated; the overlap was unspecified, and it is decided here on
which fact an operator can act: the head is fresh, so consuming it resolves the
refusal, whereas renewing the record they named would not.

**Consequence, stated plainly:** production's `CADV-000001` is both superseded
and expired, so it now refuses as `advertisement-record-superseded` where G11-G
§13 recorded `advertisement-not-fresh`. That change is deliberate and is pinned
by a test.

---

## 11. R16 — GREEN matrix

Every state pinned to its own outcome, and every refusal allocating nothing:

| Advertisement state | Outcome | Reason |
|---|---|---|
| **current + fresh** | `preflight` / `accepted` | — |
| **superseded + fresh** | `refused` | `advertisement-record-superseded` |
| **current + expired** | `refused` | `advertisement-not-fresh` |
| **superseded + expired** | `refused` | `advertisement-record-superseded` |
| the renewal itself | `accepted` | — the rule excludes the predecessor, not the lineage |
| chain forked | `refused` | `advertisement-chain-forked` |
| chain cyclic | `refused` | `advertisement-chain-cyclic` |
| chain incoherent | `refused` | `advertisement-chain-incoherent` |

```
PASS: a superseded but still-fresh advertisement refuses as superseded
PASS: a temporally fresh advertisement is never reported as stale
PASS: a current but expired advertisement refuses as not fresh
PASS: an advertisement that is both superseded and expired reports superseded
PASS: the renewal itself is admissible
PASS: a forked advertisement chain refuses
PASS: a cyclic advertisement chain refuses
PASS: an unreadable advertisement chain refuses
    -> every one of the above: no instance written, capability-instance.seq absent
```

### R15 GREEN

```
PASS: a first admission rehearses to preflight (got preflight/None)
PASS: the rehearsal names no record
PASS: the same body is accepted when written
PASS: the written identity is the predicted one (CINST-000001)
PASS: the rehearsal and the write share one request digest
PASS: a superseding admission still rehearses to preflight
```

### R15 GREEN through the released CLI — where the gap actually was

```
PASS: the CLI preflight of a first admission exits zero (got 0)
PASS: the CLI preflight reports would_accept true
PASS: the CLI preflight rehearsal outcome is preflight
PASS: the CLI preflight predicts CINST-000001
PASS: the CLI preflight reports mutating nothing
PASS: the CLI preflight reports the destination absent
    -> CLI preflight: no instance written, capability-instance.seq absent
```

---

## 12. The coverage gap, and two pre-existing defects

### Why the suite missed R15 and R16

**R15** — only **two** operations were ever exercised through `--preflight`
anywhere in the repository:

```
1  select              (added by G11-C)
1  declare-package
```

Nine of the eleven write operations, `admit-instance` among them, had never been
rehearsed by a test. The write path was correct, so every existing admission
test passed; the defect lived exclusively in a path nothing ran.

**R16** — every admission fixture used an advertisement that was fresh **and**
current at the same time, so the two properties were never separated. A test
world that only ever builds a good advertisement cannot discover that one of its
two good properties is unchecked.

**Both gaps are closed permanently** by
`tests/test-fabric-instance-admission-integrity.sh`, registered in local
validation and in CI.

### Two pre-existing defects, corrected in their own commits

Both are **stale-bound assertions** that began failing when the operator
installed Generation 11 in G11-E. Neither is related to R15/R16. Both are proven
pre-existing: the files are **byte-identical to `0c76297`**, so the code that
failed is the committed code, and only production had moved.

**(a) `tests/test-capability-execution-generation11-installer.sh`** — commit
`4f333c5`. It asserted *"production carries no installed Fabric package"*. That
was a fact about the host on the day G11-D wrote it, not an invariant. 121 of
its 122 assertions passed; this was the only failure. Replaced with the actual
invariant: this suite installs nothing (already proven by its production
snapshot), and if a Fabric package **is** installed it is exactly the nine
reviewed objects with no write-plane module.

**(b) `tests/test-fabric-runtime-install-closure.sh`** — commit `0fc0693`. Two
defects in one suite:

1. It builds a disposable root by copying the installed tree and overlaying the
   reviewed surface. Installed objects are `0444`; before installation the
   overlay *created* those nine files, and now the copy already supplies them,
   so the overlay wrote over read-only files and the suite died with
   `Permission denied` before asserting anything.
2. **Worse, its negative control had gone vacuous.** The control builds a root
   with one required module "skipped" and asserts the import fails naming that
   module — but `skip` only declined to *overlay* it. Nothing else supplied it
   before; the installed copy supplies it now. The control would have found the
   module present and proved nothing.

The first fails loudly, the second silently. A skipped module is now **removed**
from the root, and the fixture is made writable after the copy.

**These are the same class of defect G11-B §13 warned about** — suites bound to
a moment rather than to an invariant — and they are the second and third
instances in this programme. Neither was buried in the implementation commit.

---

## 13. Changed files and installed-runtime classification

| Commit | File | Installed in the G11 closure? |
|---|---|---|
| `4f333c5` | `tests/test-capability-execution-generation11-installer.sh` | no — test |
| `0fc0693` | `tests/test-fabric-runtime-install-closure.sh` | no — test |
| `a944cd9` | **`tools/fabric/admission.py`** | **NO — on `GENERATION_11_EXCLUDED`** |
| `a944cd9` | `tests/test-fabric-instance-admission-integrity.sh` (new) | no — test |
| `a944cd9` | `tools/dev/run-validation.sh` | no |
| `a944cd9` | `.github/workflows/ci.yml` | no |

**Verified rather than assumed**, from the reviewed surface declaration:

```
installed closure (9)  __init__.py errors.py identifiers.py models.py
                       request_identity.py evidence.py store.py
                       validator.py inspection.py
excluded (5)           admission.py cli.py eligibility.py selection.py
                       trust_adapter.py
/usr/lib/kyri/python/tools/fabric/admission.py : NOT PRESENT
```

`admission.py` is operator-side write/control-plane source. It is not installed,
so **no generation is opened and Generation 11 is not reinstalled.** No other
changed file lies inside the closure, so no installation consequence arises.

`G11_RUNTIME_REINSTALL_REQUIRED = NO`.

---

## 14. Validation

From the clean implementation commit `a944cd9`, worktree clean.

| Check | Result |
|---|---|
| focused suite `test-fabric-instance-admission-integrity.sh` | **PASS — 38 assertions** |
| `test-capability-execution-generation11-installer.sh` | **PASS — 122 assertions** |
| `test-fabric-runtime-install-closure.sh` | **PASS** — negative control meaningful again |
| `test-fabric-g11-integrity.sh`, `test-fabric-runtime.sh`, `test-capability-fabric.sh` | **PASS** (via the full validator) |
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh --quick` | **PASS — 74/74** |
| `tools/dev/run-validation.sh` | **PASS (full) — 95/95** |

```
Validation passed (full mode), started 2026-08-28T12:54:38-05:00, 95/95 steps.
```

Full validation was mandatory because repository `HEAD` changed. The full total
moved 94 → 95 for the new suite and was **re-measured in both modes** rather
than incremented; quick is unchanged at 74 because the suite registers in the
full-only branch.

### Commit ordering

The three commits were **reordered before pushing** so that each validates
independently. As first written, the implementation landed before the second
test correction, which would have left `a944cd9` failing the validator on a
defect it did not cause. Final order:

```
4f333c5  fix(tests): unbind the generation-11 installer suite from the pre-install era
0fc0693  fix(tests): unbind the installed-closure suite from the pre-install era
a944cd9  fix(fabric): harden instance admission rehearsal and advertisement currentness
```

---

## 15. Production non-mutation proof

| Authority | Before | After | |
|---|---|---|---|
| Fabric | `6428520119fd10e5bcd6f4dd0b3bb99f6fc6181dc5bcfd7f27e8131798219a30` | same | **BYTE-IDENTICAL** |
| Trust | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | same | **BYTE-IDENTICAL** |
| Artifact | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | same | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | same | **BYTE-IDENTICAL** |
| Installed runtime | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | same | **BYTE-IDENTICAL** |
| `CADV-000001` | `cb2e16c7…e195` | same | **UNCHANGED** |
| `CADV-000002` | `555f9a8d…2454` | same | **UNCHANGED** |

`diff` of the before and after captures: **identical**.

```
CADV = 2      CINST = 0     CROUTE = 0     CSEL = 0
capability-instance.seq : absent
installed runtime       : 57 objects
/etc/kyri/fabric/cinst-000001.json : absent
Root Authority          : unmounted
```

Every fixture in every suite runs in a temporary root, and both the new suite
and the two corrected ones assert the production Fabric and Trust stores are
unchanged as their own final check.

**No privileged operation. Every command ran as uid 1000.**

---

## 16. `CADV-000002` freshness, and what R17/R18 mean for the next ceremony

```
report time   2026-08-28T12:56-05:00
expires       2026-08-29T09:24:51-05:00
remaining     20h 23m
verdict       FRESH
```

**Comfortably fresh** — well above the 12-hour margin the previous checkpoint
set. The recommendation in §18 follows from that.

R17 and R18 are body policy and are recorded here **without being encoded
anywhere**:

- **R17** — `admitted_at = evaluated_at`, `admitted_until = admitted_at + 24h`,
  applied when the next candidate body is generated. **No schema default was
  added**, no global automatic duration was introduced, and **no
  `admitted_until <= advertisement.valid_until` coupling was created** — the
  ruling forbids inventing one, and committed architecture does not require it.
  Admission expiry and advertisement expiry remain independent clocks.
- **R18** — `admission_decision_id` for `CINST-000001` is
  `eng-0005-cinst-000001-admission`. This supersedes the placeholder
  `g11g-admission-approval-cpkg-0001-chost-0001` used in the G11-G candidate.
  **No grammar, pattern or validation was added** for the field; it remains
  free operator text held to `_text`.

Both take effect in the next checkpoint, when the body is regenerated.

---

## 17. Actions NOT performed

- **`CINST-000001` not created.** `capability-instance.seq` still absent.
- **No CINST operator input frozen.** `/etc/kyri/fabric/cinst-000001.json`
  absent.
- **No `CADV-000003` created**; `CADV-000001` and `CADV-000002` both unchanged.
- **No CROUTE, no CSEL. No package staged, no capability invoked.**
- **Generation 11 not reinstalled**; installed runtime byte-identical (§13).
- **Trust, Artifact and Platform Evidence not mutated.**
- **Root Authority not mounted.**
- **Renewal semantics not altered** — `register_advertisement` untouched.
- **The minted-identity guard not deleted or weakened** (§7).
- **No second lineage traversal written** (§10).
- **No supersession validation relaxed for committed writes.**
- **No R17 duration default or advertisement/admission coupling encoded** (§16).
- **No R18 grammar created** (§16).
- **The two pre-existing test corrections not buried** in the implementation
  commit (§12).
- **No privileged operation, no `sudo`.**
- **No secrets recorded.**

---

## 18. Unresolved findings

1. **No admission-window duration policy exists in committed architecture.**
   R17 settles the bootstrap value by explicit ruling; whether a durable policy
   surface should exist remains open, and the ruling deliberately declines to
   create one now.
2. **`data-classification-not-permitted-by-host` remains unreachable** in this
   lineage (G11-G §18) — both grants carry only `internal`. An artifact of a
   single-classification fabric, not a defect.
3. **Preflight coverage is still narrow.** This checkpoint added
   `admit-instance`; `select` and `declare-package` were already covered.
   **Eight write operations remain unrehearsed by any test** — `declare-capability`,
   `declare-contract`, `admit-subject`, `create-route`, `withdraw-subject`,
   `refresh-subject`, `withdraw-instance`, `retire-instance`. R15 was one defect
   found in the first of those paths anyone looked at. Worth a dedicated
   checkpoint.
4. **Carried forward, unrelated:** the Artifact digest discrepancy (G11-D §18,
   G11-E §18) and the two lagging execution helper modules (G11-E §10.1).

---

## 19. Recommended next checkpoint

**Regenerate the `CINST-000001` candidate against `CADV-000002` and rehearse it
— G11-G, resumed.**

`CADV-000002` is fresh with ~20h remaining, so **no new advertisement is needed**
and `CADV-000003` should **not** be created.

The next checkpoint should:

1. regenerate the body with a fresh clock read, applying **R17**
   (`admitted_until = admitted_at + 24h`) and **R18**
   (`admission_decision_id: eng-0005-cinst-000001-admission`);
2. re-run the fixture rehearsal and the twenty negative controls from G11-G,
   which should now show `preflight` where they showed
   `supersedes-different-capability`;
3. obtain a genuine **`would_accept: true`** production preflight — the gate that
   was impossible before this checkpoint;
4. freeze the operator input at `root:cschott 0640`;
5. and only then, under separate authorisation, spend `CINST-000001`.

**Watch the clock.** If `2026-08-29T09:24:51-05:00` passes before step 5, publish
`CADV-000003 supersedes CADV-000002` through the proven G11-F renewal path and
regenerate against it. **Do not weaken freshness** — and note that after this
checkpoint the refusal for consuming a superseded advertisement is
`advertisement-record-superseded`, not staleness, so a stale-vs-superseded
distinction now shows up correctly in the operator's output.

---

## Appendix A — commands executed

All read-only against production; every fixture write landed in a temporary
root. **No `sudo` at any point.**

```bash
# Phase 0
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <each G11-A..G commit> HEAD
find /usr/lib/kyri/python -type f -name '*.py' | wc -l          # 57
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )

# Classification, before touching anything
source provisioning/execution/generation-11-surface.sh   # 9 installed, 5 excluded
test -e /usr/lib/kyri/python/tools/fabric/admission.py   # absent

# RED, against released source
python3 <red-g11h.py> <g11g candidate body>              # A1-A4, B all true

# Vocabulary survey
grep -n 'REASON_.*= "' tools/fabric/admission.py | grep -iE 'head|supersed|current|stale'

# Implementation
<edit tools/fabric/admission.py: scope the guard; require advertisement head;
 add REASON_ADVERT_SUPERSEDED>

# GREEN
python3 <red-g11h.py> ...                                # A1 and B now false
bash tests/test-fabric-instance-admission-integrity.sh   # 38 assertions

# Pre-existing defects, proven pre-existing
git diff --stat 0c76297 -- <each failing suite>          # empty: unchanged
bash tests/test-capability-execution-generation11-installer.sh   # 121 pass, 1 fail
bash tests/test-fabric-runtime-install-closure.sh

# Validation from the clean implementation commit
git diff --check ; tools/dev/run-shellcheck.sh
pre-commit run --all-files
tools/dev/run-validation.sh --quick     # 74/74
tools/dev/run-validation.sh             # 95/95

# Production non-mutation
<authority digests re-taken and diffed against the Phase-0 capture>
```

## Appendix B — the two corrections, stated once

```
R15  admit_instance, at the commit point

     WRITE                                 REHEARSAL
     allocated = 'CINST-000001'            allocated = None
     supersedes = None                     supersedes = None

     before:  allocated == supersedes
              'CINST-000001' == None       None == None
              False                        TRUE   -> refused
                                                     'supersedes-different-
                                                      capability'

     after:   allocated is not None and (allocated == supersedes or ...)
              True and False               False and ...
              False                        False  -> preflight

     The guard proves a minted identity is not the one it supersedes.
     A rehearsal mints nothing, so there is nothing for it to say.
     Unchanged for every write. Still fires when an allocator is damaged.


R16  admit_instance, among the advertisement checks

     resolve advertisement
       ├── belongs to this host      advertisement-not-of-subject
       ├── belongs to this contract  advertisement-not-of-contract
       ├── belongs to this package   advertisement-not-of-package
       ├── IS THE CHAIN HEAD         advertisement-record-superseded   <-- new
       │     advertisement_head(store, id) == id
       │     forked / cyclic / incoherent all fail closed through
       │     the SAME traversal the renewal rule already uses
       └── clocks                    advertisement-not-fresh

     freshness  = is this claim still true?          -> renew
     head-ness  = is this claim still the host's?    -> consume the head

     Two facts. Two remedies. Two reasons.
```
