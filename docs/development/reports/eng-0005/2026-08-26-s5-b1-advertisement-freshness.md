# ENG-0005 S5-B1 — Advertisement Freshness Admission Hardening

**Date:** 2026-08-26
**Checkpoint:** S5-B1
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Implement only the admission-time freshness correction required
by reviewer ruling R13. Do not freeze or write `CADV-000001`. Do not implement
general advertisement supersession. Do not touch CINST, selection, or installed
Generation 10.

**Outcome: ACCEPTED.**

`register_advertisement` now requires `observed_at <= recorded_at < valid_until`,
judged against the governed request's own `recorded_at` and never against a
clock. The defect S5-B0 discovered — an already-closed validity window accepted
and written as a permanent record no evaluation could ever find fresh — is
closed, with RED-first tests proving it existed and GREEN tests proving it does
not.

- Focused RED reproduced the defect against the **real admission operation**.
- Implementation is **14 added lines** in one function, all comment except two
  lines of logic.
- Full validator passes **91/91 from the clean implementation commit**.
- **No production state changed.** `CADV` count 0, advertisement sequence
  absent, `CADV-000001` unspent, `/etc/kyri/fabric/cadv-000001.json` absent.
- `tools/fabric` is **repository-only** — not an installed object in any
  generation installer — so nothing installed changed and Generation 11 is not
  opened.

**One deviation from the expected two-commit shape**, disclosed prominently:
a **pre-existing, unrelated** test failure blocked the required validator gate.
It was corrected in its own commit ahead of the implementation commit, so the
freshness change is reviewable in isolation and the validator genuinely passes
from the clean implementation commit. See §12 and question Q3.

---

## 2. Reviewer rulings applied

### R12 — bootstrap advertisement freshness policy

For the first manual/bootstrap execution path, advertisement validity duration
is **24 hours**; the intended first body will use
`valid_until = observed_at + 24 hours`.

**This is an explicit operator/reviewer bootstrap policy. It was not derived
from ADR-0012, and nothing in this checkpoint claims that it was.** ADR-0012:809
continues to state that advertisement freshness windows are unenforced until a
runtime exists. Accordingly, **no duration was encoded anywhere in this
change** — not in the schema, not in the model, not in the implementation. The
24-hour value belongs to the `CADV-000001` operator decision and its report.
When an automated runtime exists, freshness policy may be governed differently.

### R13 — admission-time freshness invariant — **implemented here**

`register_advertisement` must require `observed_at <= recorded_at < valid_until`,
using the governed request's `recorded_at`, never ambient current time.
Therefore `observed_at > recorded_at` refuses; `valid_until == recorded_at`
refuses; `valid_until < recorded_at` refuses. The existing requirement
`valid_until > observed_at` remains.

Implemented exactly as ruled (§5), proven deterministic (§7).

### R14 — first-advertisement supersession

`CADV-000001` has no predecessor: `supersedes = none`, `superseded_by = none`.
The missing released supersession/renewal path does not block `CADV-000001`.
However, **no second advertisement may be treated as an unrelated renewal by
policy** — before `CADV-000002`, a governed renewal/supersession mechanism must
be established or a new explicit ruling received.

**Recorded as blocker #6 in §14.** No supersession was implemented here.

---

## 3. Phase 0 — starting authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | identical | PASS |
| HEAD contains | `49a2aac2923a536ea9b0a880139f3e3504770e2a` | HEAD **was** `49a2aac…` | PASS |
| Worktree | clean | clean, no untracked | PASS |
| CADV count | 0 | 0 | PASS |
| Advertisement sequence | absent | `capability-advertisement.seq` does not exist | PASS |
| Fabric digest | `9cfcc8de…27aa4a` | identical | PASS |
| Trust | unchanged and valid | `cffd362c…fbbc39`, `valid: true`, `problems: []` | PASS |
| Artifact authority | unchanged | `63db66fd…8bec25` | PASS |
| Platform Evidence | unchanged | `227abde8…20984b` | PASS |
| `/etc/kyri/fabric/cadv-000001.json` | absent | absent | PASS |
| Root Authority | unmounted | not a mountpoint | PASS |

Trust counts at start: `authority 1, record 2, decision 2, evidence 7, lineage 3, audit 4`.

---

## 4. Root cause

`tools/fabric/admission.py`, `register_advertisement.preflight()`, as of
`49a2aac`:

```python
_aware(recorded_at)
_aware(observed_at)
_aware(valid_until)
if valid_until <= observed_at:
    _refuse(REFUSED, REASON_WINDOW)
```

The only temporal rule was **internal to the window**: `valid_until` must be
strictly after `observed_at`. The window was never related to the request that
carried it. `recorded_at` was validated as timezone-aware and then never used
in any comparison.

Consequences, both realised in S5-B0 and reproduced here:

1. **An already-closed window is accepted.** A body observing a window that
   ended weeks before `recorded_at` is well-formed by the old rule and is
   written as a permanent record. `eligibility.py` ELIG-6 requires
   `observed_at <= instant < valid_until` at evaluation, so no instant at or
   after registration can ever satisfy it. The record is immutable
   (`update_methods: none`, `delete_methods: none`) and has irreversibly
   consumed an advertisement identity.
2. **A not-yet-open window is accepted.** A host may register a claim about a
   future it has not reached — a self-report about a state it cannot have
   observed.

The defect is narrow: it is not that staleness went unchecked (ELIG-6 checks it
at evaluation), but that **registration would durably record a claim that
evaluation could never accept**.

---

## 5. Implementation

One function, `tools/fabric/admission.py`, `register_advertisement.preflight()`.
Fourteen lines added, twelve of them comment:

```python
        _aware(recorded_at)
        _aware(observed_at)
        _aware(valid_until)
        if valid_until <= observed_at:
            _refuse(REFUSED, REASON_WINDOW)
        # **The window must cover the moment the claim is recorded.** A
        # well-formed window is not enough: one that closed before the request
        # carrying it, or that opens after it, describes a claim that was never
        # true at the only instant this record can speak for. Registering it
        # would spend an immutable identity on a record that no evaluation
        # could ever find fresh, and an append-only store cannot take it back.
        #
        # Judged against `recorded_at` -- the governed request's own instant --
        # and never against a clock. Reading the current time here would make
        # the verdict depend on when the request was replayed rather than on
        # what it says, so a body accepted once could be refused later without
        # a single byte of it changing.
        if not observed_at <= recorded_at < valid_until:
            _refuse(REFUSED, REASON_WINDOW)
```

**Placement.** In `preflight()`, immediately after the existing window check.
This is where the existing temporal rule already lives, and it is the phase that
runs *before* the request is identified — the module's own stated ordering,
"syntax is structure, so it is judged before the request is identified." The
check depends only on values supplied in the body, so it belongs there, and a
refusal spends no request identity and writes nothing.

**Why the existing check is kept.** `observed_at <= recorded_at < valid_until`
logically implies `valid_until > observed_at`, so the first check is redundant
as a guard. It is retained because R13 states it remains, and because it
preserves the diagnostic ordering: a reversed window is reported as a reversed
window even when `recorded_at` also falls outside it.

**Scope discipline.** No change to eligibility, selection, instance admission,
routes, the model dataclass, identifiers, the store, or the CLI. No new
constant, no new parameter, no configuration key, no duration.

---

## 6. Refusal behaviour

**Reused `REASON_WINDOW` = `invalid-validity-window`. No new governed reason
was introduced.**

The existing vocabulary was inspected in full — 60 `REASON_*` constants in
`admission.py`. It is notably granular: four distinct `supersedes-*` reasons,
three distinct chain reasons (`forked` / `cyclic` / `incoherent`), and
`advertisement-not-fresh` already exists for staleness at **evaluation** time,
distinct from `invalid-validity-window`.

That granularity was weighed as an argument for splitting future-observation and
already-closed into separate governed reasons. It was **rejected**, on the
reading that the window is not a free-floating object: it is the validity window
*of this request*. A window that never covered its own request is invalid for
that request, and `invalid-validity-window` states exactly that. R13's guidance
prefers reuse, and the reading is coherent rather than a stretch — so no
vocabulary was added.

**The tension is real and is surfaced rather than buried**, because a caller
reading only the reason token cannot distinguish "you reversed the bounds" from
"you are registering a dead claim" from "you are claiming a future observation",
and those imply different operator actions. Raised as **Q1** for the reviewer.
Splitting later is additive and cheap; it was not done silently here.

Resulting behaviour, all `outcome = refused`, `reason = invalid-validity-window`:

| Relationship | Verdict |
|---|---|
| `valid_until <= observed_at` (reversed / zero-length) | refuse — **unchanged** |
| `valid_until < recorded_at` (window already closed) | refuse — **new** |
| `valid_until == recorded_at` (closes exactly at recording) | refuse — **new** |
| `observed_at > recorded_at` (future observation) | refuse — **new** |
| `observed_at == recorded_at < valid_until` | **accept** |
| `observed_at < recorded_at < valid_until` | **accept** |

Naive or malformed instants continue to be refused earlier, as
`timestamp-carries-no-offset` / unusable invocation — **unchanged**.

---

## 7. Deterministic-time proof

**The verdict depends only on `observed_at`, `recorded_at` and `valid_until`
from the governed request.**

**Static.** A scan of the entire module for every ambient-time and
environment-derived source returns nothing:

```
$ grep -nE "datetime\.now|utcnow|time\.time|time\.monotonic|date\.today|os\.environ|getmtime|st_mtime|st_ctime" tools/fabric/admission.py
  (no matches)
```

No `datetime.now()`, no `time.time()`, no system clock, no environment-derived
time, no filesystem timestamp — not in the new check, and not anywhere in
`admission.py`. The comparison reads three parameters of the governed request
and nothing else.

The validator independently enforces this: step *"the admission controller
opens no network, environment, worker, or caching path"* passes.

**Dynamic.** The same body, submitted three times with real wall-clock advancing
between submissions, produces an identical verdict:

```
verdicts across advancing wall-clock:
  [('refused', 'invalid-validity-window'),
   ('refused', 'invalid-validity-window'),
   ('refused', 'invalid-validity-window')]
all identical: True
```

**In-suite.** A permanent regression test pins it:

```python
    # The verdict comes from the three governed instants and nothing else, so
    # the same request replayed under a different request identity -- and at a
    # different wall-clock moment -- decides the same way. A check reading the
    # system clock could not promise this.
    stale_body = {"observed_at": STAMP - timedelta(hours=2),
                  "valid_until": STAMP - timedelta(hours=1)}
    first = advertisement(..., request_id="req-adv-det-1", **stale_body)
    second = advertisement(..., request_id="req-adv-det-2", **stale_body)
    check(first.record_id is None and second.record_id is None
          and first.reason == second.reason,
          "the freshness verdict depends only on the governed instants")
```

**A byte-identical request evaluated against the same authority produces the
same temporal verdict regardless of when it is replayed.**

---

## 8. RED reproduction, exactly

The cases were added to `tests/test-fabric-runtime.sh` **before** any
implementation change, and exercise the real `register_advertisement`
operation — not model construction.

### First RED run — 5 failures

```
FAIL: an advertisement carrying a window that closed before the request was recorded is refused
FAIL: an advertisement carrying a window that closed before the request was recorded writes nothing
FAIL: an advertisement with an observation instant equal to the recording instant is accepted
FAIL: an advertisement with a window recorded strictly inside it is accepted
FAIL: the freshness verdict depends only on the governed instants
```

Two of the three new refusal cases did **not** fail — and diagnosis showed they
were passing for the wrong reason. Recorded because it matters to how much the
RED proves:

```
DIAG 'a window that closed before the request was recorded' -> accepted, id=CADV-000001
DIAG 'a window that ends exactly when the request is recorded' -> conflict, request_identity_conflict
DIAG 'an observation instant after the request was recorded'   -> conflict, request_identity_conflict
DIAG accept-case 'an observation instant equal to the recording instant' -> invalid, malformed-operation-content
```

Two defects in the newly-written tests, both mine:

1. The existing refusal loop shared a single `request_id="req-adv-bad"`. That is
   safe **only while every case refuses**. The moment the genuine RED case was
   accepted, it wrote a record under that identity and the following cases
   collided with it, reporting `request_identity_conflict` instead of the defect
   under test. Corrected to one request identity per case.
2. The accept-case slug was built from a description containing spaces, yielding
   a malformed request identity. Corrected to explicit slugs.

### Second RED run — the honest RED

```
PASS: an advertisement carrying a window that ends when it starts is refused          (preserved)
FAIL: an advertisement carrying a window that closed before the request was recorded is refused
FAIL: an advertisement carrying a window that closed before the request was recorded writes nothing
FAIL: an advertisement carrying a window that ends exactly when the request is recorded is refused
FAIL: an advertisement carrying a window that ends exactly when the request is recorded writes nothing
FAIL: an advertisement carrying an observation instant after the request was recorded is refused
FAIL: an advertisement carrying an observation instant after the request was recorded writes nothing
PASS: an advertisement with an observation instant equal to the recording instant is accepted
PASS: an advertisement with a window recorded strictly inside it is accepted
FAIL: the freshness verdict depends only on the governed instants
→ 7 error(s)
```

Exactly the R13 matrix: three refusal relationships failing (each asserted twice
— refused, and writes nothing), the determinism pin failing, both accept
relationships already correct and therefore proving the change does not
over-refuse, and the pre-existing window and naive-instant cases still passing.

### Cases added, permanently

```python
        # The window must cover the moment the claim is being registered.
        # `recorded_at` is the governed request's own instant, so the verdict
        # is a property of the request rather than of when it was replayed.
        ({"observed_at": STAMP - timedelta(hours=2),
          "valid_until": STAMP - timedelta(hours=1)},
         "a window that closed before the request was recorded"),
        ({"observed_at": STAMP - timedelta(hours=1), "valid_until": STAMP},
         "a window that ends exactly when the request is recorded"),
        ({"observed_at": STAMP + timedelta(hours=1),
          "valid_until": STAMP + timedelta(hours=2)},
         "an observation instant after the request was recorded"),
```

plus the two accept cases and the determinism pin quoted in §7.

---

## 9. Focused GREEN

After the implementation change, the same suite:

```
PASS: an advertisement carrying a window that ends when it starts is refused
PASS: an advertisement carrying a window that ends when it starts writes nothing
PASS: an advertisement carrying a window that closed before the request was recorded is refused
PASS: an advertisement carrying a window that closed before the request was recorded writes nothing
PASS: an advertisement carrying a window that ends exactly when the request is recorded is refused
PASS: an advertisement carrying a window that ends exactly when the request is recorded writes nothing
PASS: an advertisement carrying an observation instant after the request was recorded is refused
PASS: an advertisement carrying an observation instant after the request was recorded writes nothing
PASS: an advertisement with an observation instant equal to the recording instant is accepted
PASS: an advertisement with a window recorded strictly inside it is accepted
PASS: the freshness verdict depends only on the governed instants
```

Preserved, unchanged: `a window that ends when it starts`, `a reversed validity
window`, `a naive observation instant`, `a naive validity boundary`.

**Whole suite: 8296 PASS, 0 FAIL — `Fabric runtime validation passed.`**

### Fixtures the correction invalidated, and why each change is faithful

The change broke 13 pre-existing assertions. Every one was a fixture that
depended on the defect. None was a semantic regression. Each was inspected
individually rather than adjusted until green.

| Fixture | Was | Why it broke | Correction |
|---|---|---|---|
| `stale_adv` (§I7 prerequisite matrix) | `recorded_at=STAMP`, window `STAMP-3d → STAMP-2d` | dead on arrival; only registrable because of the defect | `recorded_at=STAMP-3d` — registered **while live**, lapses relative to the admission's `evaluated_at` |
| `future_adv` | `recorded_at=STAMP`, window `YEAR → YEAR+1d` | future observation | `recorded_at=YEAR` — recorded when observed |
| `revived` ("a returning host may publish a fresh advertisement") | `recorded_at=STAMP`, window `YEAR → YEAR+1d` | the host returns *at* `YEAR`; recording at `STAMP` a window a year later is the nonsense R13 forbids | `recorded_at=YEAR` |
| advertisement identity matrix, `("recorded_at", LATER)` | `LATER == valid_until` | mutation lands exactly on the window's exclusive end, so it is refused before identity is classified | `STAMP + 1h` — inside the window |
| VALID_CHANGES matrix, `("recorded_at", LATER)` | same | the block tests *structurally valid* changes; this one stopped being structurally valid | `STAMP + 1h` |
| `conflicting` claim, `observed_at=STAMP + 1h` | `> recorded_at` | refused before the identity conflict it exists to prove | `STAMP - 1h` — still inside, still different |

The `stale_adv` / `future_adv` corrections are the substantive ones. The CINST
checks *"an instance admission with a stale advertisement is refused as
advertisement-not-fresh"* and *"...not yet valid..."* still exist and still pass.
They now describe the real scenario — **a claim registered while it was live,
evaluated after it lapsed** — instead of a claim that was never valid at any
instant. That is a strictly better fixture: the old one could only be built
because registration accepted dead claims.

### Runtime semantics outside advertisement freshness are unchanged

- Full validator **91/91**, including the fabric runtime suite in its entirety
  (8296 assertions), eligibility, selection, instance admission, routes, trust
  integration, and every capability-execution suite.
- The production-path backstop passes: *"production paths unchanged"*.
- The platform-model mutation backstop passes.
- Only `register_advertisement` changed; no other operation's code path was
  touched.

---

## 10. Schema and documentation changes

Both are **normative prose only**. No machine-readable policy was added — in
particular **no `validity_duration: 24h`** or any other duration key, per R12.

**`platform-model/schemas/capability-advertisement.schema.yaml`** — the schema
previously listed `observed_at` and `valid_until` in `required_fields` with no
prose about their relationship at all, so it did not merely *understate* the
corrected behaviour, it stated nothing. Added above the two fields:

```yaml
  # The validity window, and it must cover the moment the claim is recorded:
  # observed_at <= recorded_at < valid_until. A window that is merely
  # well-formed is not enough. One that closed before the request carrying it,
  # or that opens after it, describes a claim that was never true at the only
  # instant the record can speak for, and registering it would spend a
  # permanent identity on something no evaluation could ever find fresh.
  #
  # Judged against the governed request's own recorded_at, never against a
  # clock, so the verdict is a property of the request rather than of when it
  # was replayed. Staleness *after* registration is a different question,
  # asked at evaluation time against the instant being evaluated.
```

**`docs/fabric/node-model.md`** — the section "What cites which record" already
said an advertisement is *"a claim published by a subject as it is now"*.
Extended so the phrase also binds the window:

> *As it is now* also binds the validity window: it must cover the moment the
> claim is recorded, so a window that has already closed, or that has not yet
> opened, is refused at registration rather than stored as a claim nothing could
> ever find fresh.

`docs/fabric/capability-lifecycle.md` and ADR-0012 describe the *evaluation-time*
clock ("claim is stale; instance ineligible"), which is unchanged and correct.
Neither was edited.

---

## 11. Validation results

All run from the **clean implementation commit** `90597fe…`, worktree clean:

| Check | Result |
|---|---|
| `git diff --check` | **PASS** — no whitespace errors |
| `tools/dev/run-shellcheck.sh` | **PASS** — ShellCheck 0.9.0, exit 0 |
| `pre-commit run --all-files` | **PASS** — shell syntax, shellcheck, whitespace, no tracked bytecode, static repository assertions |
| `tools/dev/run-validation.sh` | **PASS (full mode) — 91/91 steps** |
| `tests/test-fabric-runtime.sh` | **PASS** — 8296 assertions, 0 failures |

```
Validation passed (full mode), started 2026-08-26T13:55:44-05:00, 91/91 steps.
```

Backstops within the validator that bear on this checkpoint:

```
[88/91] Runtime evidence backstop   ok  no committed runtime evidence, no partial writes
[89/91] Production path backstop    ok  production paths unchanged (/var/lib/kyri:present /etc/kyri:present)
[90/91] Platform model mutation     ok  platform-model unmodified
```

---

## 12. Pre-existing failure encountered — disclosed

**The first full-validator run failed at step 23 of 91, on a defect that
predates this checkpoint entirely.**

```
[23/91] Fabric host admission
FAIL: capability-host.seq was created
FAIL: a CHOST record appeared
→ Validation stopped at step 23. Nothing after it ran.
```

`tests/test-fabric-host-admission.sh` asserted, absolutely, that the production
Fabric store contains **no** `CHOST` record and **no** `capability-host`
sequence. That was true when the suite was written and stopped being true when
`CHOST-0001` was admitted in S4-A on 2026-08-25. The backstop therefore reported
an accepted governed record as the suite's own leakage.

**Proven pre-existing**, not caused by this work: the change was stashed, the
suite run at the clean HEAD `49a2aac`, and it failed identically.

```
$ git stash push --include-untracked && bash tests/test-fabric-host-admission.sh
FAIL: capability-host.seq was created
FAIL: a CHOST record appeared
```

Neither S5-A1 nor S5-B0 ran the full validator — both were ceremony checkpoints
— which is why this surfaced now.

**Disposition.** The required gate ("full validator must pass from the clean
implementation commit") could not be met without addressing it, and abandoning
the completed and verified R13 work over an unrelated stale assertion would have
been over-blocking. It was corrected **in its own commit, placed before the
implementation commit**, so that the freshness change is reviewable in isolation
and the validator genuinely passes from the implementation commit.

The correction preserves the backstop's intent — *this suite created nothing* —
by snapshotting before and comparing after, rather than asserting anything about
what production legitimately holds:

```bash
HOST_SEQ_BEFORE="$([[ -e "${FABRIC_ROOT}/sequences/capability-host.seq" ]] && echo present || echo absent)"
HOST_COUNT_BEFORE="$(find "${FABRIC_ROOT}/capability-hosts" -maxdepth 1 -type f 2>/dev/null | wc -l)"
```

`production_state` already digests the whole tree, so the byte-identity check
covers this too; the two named checks are kept for the clearer diagnostic.

Raised as **Q3**.

---

## 13. Generation classification

**`tools/fabric/admission.py` is repository-only. This change alters no
installed object, and Generation 11 is not opened.**

Established mechanically:

```
$ grep -l "tools/fabric/admission.py" provisioning/execution/install-generation-*.sh
  (no matches — not an installed object in any generation installer)

$ ls /usr/lib/kyri/python/tools/          # LIBRARY_ROOT of the generation installers
  capability  common  __init__.py  __pycache__

$ ls -d /usr/lib/kyri/python/tools/fabric
  No such file or directory
```

The installed library root is `/usr/lib/kyri/python` (`LIBRARY_ROOT`, defined at
`provisioning/execution/install-generation-10.sh:72`). Generation 10's manifest
installs exactly four objects — `tools/common/trusted_source.py`,
`tools/capability/execution/package_contract.py`,
`tools/capability/package_resolution.py`, `tools/capability/evidence.py`. No
generation installs any part of `tools/fabric`.

**Delta classification: repository-only source change. Installed object count
unchanged at 48. No CREATE, no REPLACE, no REMOVE against any installed
generation. Nothing was installed and no installation ceremony was run.**

The other files changed — a test suite, a platform-model schema, a doc — are
likewise repository-only.

**Carry-forward obligation.** Blocker #4 (§14) proposes that Generation 11
package the existing `tools.fabric` dependency rather than duplicate Fabric
logic. **If that happens, this correction must be carried into that installed
generation**, because the installed `tools/capability/fabric_evidence.py` and
`coordinator.py` both import `tools.fabric`. Verified during this checkpoint:

```
$ grep -rl "tools.fabric" /usr/lib/kyri/python/tools/capability/
  /usr/lib/kyri/python/tools/capability/fabric_evidence.py
  /usr/lib/kyri/python/tools/capability/coordinator.py
```

which independently re-confirms blocker #3 on the live installed tree.

---

## 14. Generation-11 / execution-readiness blockers — all seven

Six carried forward, one new from R14. **None implemented here.**

1. **`CapabilityInstance.advertisement_id` must become non-optional.** It is
   modeled optional while `admit_instance` requires it. Make the model
   authoritative before CINST.
2. **`admit_instance` must require the admitted host to belong to
   `effective_scope["permitted_targets"]`.** The targets dimension is only
   intersected for non-emptiness (`admission.py:597-617`); the node is never
   compared against the composed set, unlike capabilities (`:1534`) and
   classifications (`:1539`). Required tests:
   `effective targets HOST-0001 + admitted HOST-0001 → accept`;
   `effective targets HOST-0001 + admitted HOST-0002 → refuse`.
3. **Installed Capability runtime lacks `tools.fabric` dependency closure.**
   Generation 10 did not install it, so `tools.capability.fabric_evidence`,
   `coordinator` and `cli` cannot import in the installed generation.
   Re-confirmed against the live installed tree in §13.
4. **Generation 11 should provision the existing `tools.fabric`** rather than
   duplicate Fabric logic inside Capability, unless dependency-closure
   inspection demonstrates an architectural reason not to.
5. **`select` lacks genuine read-only preflight**, and this must be corrected
   before `CSEL-000001` is spent.
6. **NEW (R14) — advertisement renewal/supersession is unreachable.**
   `supersedes`, `superseded_by` and `notes` are declared on
   `CapabilityAdvertisement` and in the schema's `optional_fields`, but no
   released operation can set any of them, and nothing in `tools/` supersedes an
   advertisement. `CADV-000001` is unaffected (R14: no predecessor). **Before
   `CADV-000002`, a governed renewal/supersession mechanism must be established
   or a new explicit ruling received** — no second advertisement may be treated
   as an unrelated renewal by policy.
7. **Refusal-reason granularity for temporal invalidity** (§6, Q1). All three
   invalid temporal relationships report `invalid-validity-window`, so a caller
   reading only the token cannot distinguish a reversed window from an already
   closed one from a future observation, though the operator action differs.
   Deliberately not split; recorded so the decision is visible.

---

## 15. Changed files and commits

**Commit 1 — pre-existing, unrelated (§12):** `6f02278b98183f9962e6eef8f4f9aa35dffada6a`
`fix(tests): compare the host-admission backstop against its own snapshot`

```
 tests/test-fabric-host-admission.sh | 13 +++++++++----
```

**Commit 2 — the implementation:** `90597fe9e934447dd2bb08c551f160b605c20973`
`fix(fabric): reject stale advertisements at admission`

```
 docs/fabric/node-model.md                                |  5 +-
 platform-model/schemas/capability-advertisement.schema.yaml | 11 +++
 tests/test-fabric-runtime.sh                             | 78 +++++++++++++---
 tools/fabric/admission.py                                | 14 ++++
 4 files changed, 99 insertions(+), 9 deletions(-)
```

**IMPLEMENTATION_COMMIT = `90597fe9e934447dd2bb08c551f160b605c20973`**

Both pushed fast-forward to `arch/eng-0005-execution-transition`
(`49a2aac..90597fe`); local and remote in sync.

---

## 16. Production before / after

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric `/var/lib/kyri/fabric` | `9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a` | identical | **BYTE-IDENTICAL** |
| Trust `/var/lib/kyri/trust` | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | identical | **BYTE-IDENTICAL** |
| Artifact `/var/lib/kyri/artifacts` | `63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25` | identical | **BYTE-IDENTICAL** |
| Platform Evidence `/var/lib/kyri/evidence` | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | identical | **BYTE-IDENTICAL** |

```
CADV = 0    CINST = 0    CROUTE = 0    CSEL = 0
capability-advertisement.seq        : does not exist
/etc/kyri/fabric/cadv-000001.json   : ABSENT
Fabric sequences present            : capability-contract, capability-definition,
                                      capability-host, capability-package,
                                      request_identity.lock  (unchanged)
Trust                               : valid true, problems [], 2 records
Root Authority /mnt/kyri-root       : unmounted
```

`CADV-000001` remains **unspent**. Confirmed after the implementation commit and
after every validator run.

---

## 17. Actions explicitly NOT performed

- **`/etc/kyri/fabric/cadv-000001.json` NOT created.** Destination still absent.
- **`CADV-000001` NOT created.** Count 0, identity unspent.
- **No advertisement sequence state created.** `capability-advertisement.seq`
  still does not exist.
- **No CINST, CROUTE or CSEL** — all 0. Selection untouched.
- **No package staged. Nothing invoked.**
- **Trust not modified.** **Artifact authority not modified.** **Platform
  Evidence not modified.**
- **Root Authority not mounted.**
- **No advertisement supersession implemented** (R14 defers it; recorded as
  blocker #6).
- **No validity duration encoded anywhere** — R12's 24 hours appears in this
  report as policy, and in no schema, model, constant or configuration key.
- **No new refusal vocabulary added.**
- **Installed Generation 10 not touched. Nothing installed. Generation 11 not
  opened.**
- **No unrelated repair mixed into the implementation commit** — the one
  pre-existing failure encountered was corrected in a separate, clearly labelled
  commit ahead of it (§12).
- **No secrets recorded.**

---

## 18. Recommendation

**S5-B2 may proceed to freeze and declare `CADV-000001`.**

Grounds:

- The defect that made freezing unsafe is closed and proven closed. The precise
  hazard S5-B0 stopped on — permanently consuming the first advertisement
  identity on a claim that could never be fresh — can no longer occur.
- R12 supplies the validity duration that S5-B0 lacked. With
  `valid_until = observed_at + 24h` and `observed_at = recorded_at` at the
  ceremony instant, the body satisfies `observed_at <= recorded_at < valid_until`
  by construction.
- R14 clears the supersession question for the **first** advertisement.
- The full validator passes 91/91 from the clean implementation commit; no
  production state moved.

Suggested S5-B2 sequence:

1. Regenerate the candidate body with `valid_until = observed_at + 24h`; report
   its SHA-256 (it will differ from S5-B0's `9a400d01…2da3`, which used the same
   24-hour span but a stale ceremony instant).
2. Re-run the read-only preflight; expect `would_accept: true`,
   `predicted_record_id: CADV-000001`, `mutated: false`.
3. Operator publishes to `/etc/kyri/fabric/cadv-000001.json` with root
   (`install -o root -g cschott -m 0640`); re-verify SHA-256.
4. Re-run preflight against the frozen input.
5. Independent authorization for the single `register-advertisement` write.
6. **Stop.** Per the accepted ruling, CINST does not follow CADV — the
   Generation-11 blockers are addressed first.

**One timing caution for S5-B2.** The window is now anchored to `recorded_at`,
and a 24-hour bootstrap window is short. If the frozen body is published on one
day and the write authorized on a later one, `recorded_at` in the frozen body
will have fallen outside its own window and the write will be **refused** — the
correction working as designed. The freeze-to-write interval must sit inside the
window, or the body must be re-frozen with a current instant.

---

## 19. Questions requiring reviewer ruling

1. **Should temporal invalidity keep one refusal reason, or three?** (§6, blocker
   #7.) All of reversed-window, already-closed and future-observation report
   `invalid-validity-window`. The vocabulary elsewhere is markedly more granular,
   and the three imply different operator actions. Reuse was chosen per R13's
   preference; splitting is additive if the reviewer prefers it.
2. **Are the `stale_adv` / `future_adv` fixture corrections accepted?** (§9.)
   They change what those CINST cases *construct* — a claim registered while
   live and later lapsed, rather than one that was never valid — while the
   assertions and their reasons (`advertisement-not-fresh`) are unchanged.
3. **Is the separate pre-existing-fix commit the right disposition?** (§12.) The
   alternative was to report `BLOCKED` on an unrelated stale assertion that had
   been failing since S4-A, with the R13 work complete and verified.
4. **Should the 24-hour bootstrap window be reconsidered given §18's timing
   caution?** A window anchored to `recorded_at` means the freeze-to-authorize
   interval must fit inside it. A longer bootstrap window, or a policy of
   re-freezing immediately before the write, would both resolve it.
5. **Confirm the validator gap.** Neither S5-A1 nor S5-B0 ran
   `tools/dev/run-validation.sh`, which is why §12 surfaced only now. Should
   ceremony checkpoints run the full validator even when they change no source?

---

## Appendix A — commands executed

```bash
# Phase 0
git rev-parse HEAD ; git rev-parse --abbrev-ref HEAD ; git status --porcelain
git merge-base --is-ancestor 49a2aac… HEAD
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
<whole-tree digests: fabric, trust, artifacts, evidence>

# RED (tests added first, no implementation change)
bash tests/test-fabric-runtime.sh            # 5 failures, then 7 after test bugs fixed

# Implementation
$EDITOR tools/fabric/admission.py            # +14 lines in register_advertisement.preflight

# GREEN
bash tests/test-fabric-runtime.sh            # 8296 PASS, 0 FAIL
bash tests/test-fabric-host-admission.sh

# Determinism
grep -nE "datetime\.now|utcnow|time\.time|time\.monotonic|date\.today|os\.environ|getmtime|st_mtime|st_ctime" \
     tools/fabric/admission.py               # no matches
python3 -c "<same body, 3 submissions, wall-clock advancing between>"

# Pre-existing failure, proven at clean HEAD
git stash push --include-untracked
bash tests/test-fabric-host-admission.sh     # fails identically at 49a2aac
git stash pop

# Generation classification
grep -l "tools/fabric/admission.py" provisioning/execution/install-generation-*.sh   # none
ls /usr/lib/kyri/python/tools/                                                       # capability common
grep -rl "tools.fabric" /usr/lib/kyri/python/tools/capability/

# Required validation, from the clean implementation commit
git diff --check
tools/dev/run-shellcheck.sh
pre-commit run --all-files
tools/dev/run-validation.sh                  # 91/91, full mode
```

## Appendix B — the freshness rule, stated once

```
Registration   (tools/fabric/admission.py, register_advertisement)
    valid_until  >  observed_at                      the window is well formed
    observed_at  <= recorded_at  <  valid_until      it covers its own request
    → refused as invalid-validity-window

Evaluation     (tools/fabric/eligibility.py, ELIG-6)
    observed_at  <= instant      <  valid_until      it covers the moment asked about
    → refused as advertisement-not-fresh

Two questions, two instants, two reasons. Registration asks whether the claim
was true when it was made. Evaluation asks whether it is true now. A record that
passes the first and fails the second is a claim that lapsed, which is history.
A record that could not pass the first should never have been written.
```
