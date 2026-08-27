# ENG-0005 G11-C — Genuine Read-Only Fabric Selection Preflight

**Date:** 2026-08-26
**Checkpoint:** G11-C
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Close the final known Generation-11 source blocker: Fabric
selection must support a genuine read-only preflight before `CSEL-000001` can be
spent. The preflight must exercise the same selection semantics as the real
write path and stop before identity allocation and persistence.

**Outcome: ACCEPTED. All five known G11 source blockers are now closed.**

C6 selection was the one governed operation in the plane with no rehearsal
boundary. `select_candidate` entered the critical section unconditionally, and
its `_commit` allocated and wrote unconditionally — so the only way to learn
which binding would serve was to spend a `CSEL` identity finding out,
permanently, in an append-only store.

The correction reuses **the rehearsal abstraction the plane already has**, not a
second selection algorithm. `admission` now exports `is_rehearsing()`, so
selection reads the same context variable rather than carrying one of its own.

Proven rather than asserted: the fixture rehearses, then commits under the same
request identity, and **the predicted identity, the chosen candidate and the
request digest all match**. 28 new assertions, full validator **93/93** from the
clean implementation commit, production byte-identical.

**Nothing in the G11-B nine-file installed closure changed** — `admission.py`,
`selection.py` and `cli.py` are all on its excluded list, and the closure is
still nine modules. No pinned digest required updating.

---

## 2. Starting authority

| Gate | Observed | |
|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD | `16532ae98756a244896f0d2851443b26186e2a2d` | PASS |
| G11-A / G11-B commits | `2d6d2a0e`, `c35ccd8c`, `305f84aa`, `e9e6405e`, `16532ae9` all present | PASS |
| Worktree | clean | PASS |
| Full validator at start | passing | PASS |
| Installed generation | `CGEN-000000000001` — Generation 10 | PASS |
| Generation 11 | not installed; `tools/fabric` absent from the library root | PASS |
| `CADV-000001` | `cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195` | PASS |
| CINST / CROUTE / CSEL | 0 / 0 / 0 | PASS |
| `capability-selection.seq` | absent | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
```

**`CADV-000001`: FRESH**, 19.16 h remaining at checkpoint start. Recorded as
instructed; **it did not influence the source design** — nothing in G11-C reads,
evaluates or depends on an advertisement's window.

---

## 3. The selection path, as it was

`tools/fabric/selection.py` (C6, 560 lines) is a self-contained module. It is
*not* downstream of the admission controller — it declares its own outcome
vocabulary, its own `_Refusal`, its own `_commit` and `_constructed`.

**Input body** (via `select_candidate`): `request_id`, `actor`, `recorded_at`,
`evaluated_at`, `capability_id`, `contract_id`, `accepted_contract_versions`,
`data_classification`, `locality`, `provenance`, and the optional
`local_node_identity`, `health_removals`, `notes`.

**Validation path** — request identity, actor text, both instants aware, both
identifiers well formed, non-empty versions, classification in
`WORKLOAD_DATA_CLASSIFICATIONS`, locality in `LOCALITIES`, each health removal a
`CINST` identifier, provenance a mapping, and *supplied-but-unusable* node
identity refused as malformed rather than treated as absent.

**Then the digest**, over every governed input, via
`prepare_and_compute_request_digest`.

**Candidate resolution and evaluation** — `_resolve_route` finds the route for
the request class; `_chain_heads` reads host supersession; each declared
candidate is judged by `_exclusions`, which delegates eligibility to C5's
`evaluate_eligibility` and adds C6's own three conditions (ELIG-13 route
membership, ELIG-14 routable effect class, and route locality).

**Deterministic ordering** — the first eligible candidate in the order a human
wrote wins. There is no tie-break because declared order is already total.

**The write boundary, before this checkpoint:**

```python
def _commit(store, kind, evidence, build) -> str:
    _constructed("CSEL-000000", evidence, build)   # probe construction
    identifier = store.allocate_id(kind)           # ← irreversible
    record = _constructed(identifier, evidence, build)
    store.write(kind, record)                      # ← irreversible
    return identifier
```

and in `select_candidate`:

```python
with store.request_critical_section(identifier):   # ← store-global lock
    replay = replay_lookup(store, identifier, digest)
    ...
    record_id = _decide(...)                       # always writes
```

**Why there was no rehearsal boundary.** Every other governed operation routes
through `admission._governed`, which consults `_REHEARSING` at exactly the two
irreversible points. Selection has its own control flow and never consulted it —
so there was no point at which the path could stop, and a caller wanting to know
the answer had to spend the identity to get it.

---

## 4. RED proof

Three independent axes, before any change:

```
RED 1 — the CLI has no --preflight for select
  select --help lists: --store-root --expected-uid --expected-gid
                       --evidence-root --evidence-trusted-uid
                       --input-file --approved-directory --trust-store-root
  (no --preflight)

RED 2 — select is not a preflight-capable operation
  select in WRITE_OPERATIONS: False
  select in CREATED_KINDS   : False
  → command_preflight is keyed on WRITE_OPERATIONS, so select cannot reach it.

RED 3 — selection has no rehearsal boundary
  selection imports the shared rehearsal state : False
  selection._commit allocates unconditionally  : True
  admission exposes a public rehearsal predicate: False
  SelectionResult carries the chosen candidate  : False
```

All four RED-3 facts are now inverted, and the CLI flag exists.

---

## 5. Preflight architecture

**One rehearsal state for the whole plane.** `admission` gained a public
predicate rather than selection gaining a context variable:

```python
def is_rehearsing() -> bool:
    """Whether the caller is inside `rehearsing()`.

    Exported so every governed operation reads **one** rehearsal state. C6
    selection lives in its own module and would otherwise need a context
    variable of its own -- two states that agree until one is entered without
    the other, and then a rehearsal that writes.
    """
    return _REHEARSING.get()
```

That is the load-bearing design decision. A second `ContextVar` in
`selection.py` would work in every test and fail the first time a caller entered
one context and not the other — and the failure mode is a rehearsal that writes.

**`_commit` stops at the probe:**

```python
    _constructed("CSEL-000000", evidence, build)
    if is_rehearsing():
        return None
    identifier = store.allocate_id(kind)
    ...
```

The probe construction already applies the model's own rules to the real
content. What a rehearsal has left to learn by allocating is nothing; what it
would cost is a spent sequence position.

**`select_candidate` skips the critical section and replay:**

```python
    if is_rehearsing():
        # No critical section: it takes a store-global lock and exists to
        # serialise allocation and the accepted write, neither of which a
        # rehearsal performs. Replay is not classified either -- there is
        # nothing to serialise against, and reporting a replay for an operation
        # that was never submitted would answer about a different act.
        _, selected = _decide(...)
        return SelectionResult(PREFLIGHT, identifier, digest,
                               "capability-selection", None,
                               selected_instance_id=selected)
```

This mirrors `admission._governed`'s rehearsal branch line for line, including
the reasoning for not classifying replay.

**`SelectionResult` gained `selected_instance_id`.** A rehearsal has no record to
read the decision back from, and a preflight that named no candidate would leave
an operator with a prediction they could not compare against the write. `None` is
a real answer: nothing was eligible, or no route resolved.

**`_decide` and `_write` now return `(record_id, selected)`.** Under a rehearsal
the first element is `None`; the second is the answer either way.

### Shared semantic path — proof, not assertion

There is **no separate preflight algorithm**. The same `_decide` runs, which
means the same `_resolve_route`, the same `_chain_heads`, the same `_exclusions`,
the same `evaluate_eligibility`, and the same declared-order rule. The fixture
proves the two agree on all three observable outputs:

```
PASS: the committed selection takes the identity the rehearsal predicted
PASS: the committed selection chooses the candidate the rehearsal named
PASS: the rehearsal and the write share one request digest
PASS: the durable record names the rehearsed candidate
```

---

## 6. Zero-mutation proof

The suite snapshots the complete Fabric tree — every file's bytes — before and
after, plus every sequence file:

```
PASS: a rehearsed selection leaves the fabric byte-identical
PASS: a rehearsed selection advances no sequence
PASS: a rehearsed selection creates no selection sequence
PASS: a rehearsed selection writes no selection record
PASS: predicting the selection identity mutates nothing
PASS: a repeated rehearsal still mutates nothing
PASS: a rehearsal that selects nothing still writes nothing
PASS: a rehearsal with no route writes nothing
PASS: a rehearsal after the write leaves the record byte-identical
PASS: the select preflight command leaves the fabric byte-identical
```

A successful preflight allocates no `CSEL` identity, creates no
`capability-selection.seq`, writes no selection record, and mutates no `CINST`,
`CROUTE` or `CADV`. **It does not enter the critical section at all**, so it
writes no request-identity state either — which is a stronger guarantee than the
existing rehearsal architecture merely permits.

---

## 7. Identity prediction

Derived from store grammar, not assumed. `FabricStore.peek_next_id` reads the
sequence and applies the allocator's own candidate rule without advancing it —
the same read-only mechanism `command_preflight` already uses for the seven
creating write operations.

The identifier width comes from `tools/fabric/identifiers.py`
(`^CSEL-[0-9]{6}$`), so the first identity is `CSEL-000001` — **six digits,
derived, not taken from the brief.**

The fixture asserts the prediction against reality:

```
PASS: the command predicts the identity the store would allocate
PASS: the committed selection takes the identity the rehearsal predicted
```

**In production, after every preflight in this checkpoint:**

```
CSEL count                : 0
capability-selection.seq  : does not exist
```

---

## 8. Request-digest semantics

**The digest is unchanged, and deliberately so.**

It covers exactly the governed **inputs** that can change the result: `actor`,
`recorded_at`, `evaluated_at`, `capability_id`, `contract_id`,
`accepted_contract_versions`, `data_classification`, `locality`,
`local_node_identity`, `health_removals`, `provenance`, `notes`.

**The chosen candidate is deliberately *not* in it.** The brief asked for this
boundary to be decided and explained:

- The selected instance is a **derived output**, not an input. It is a function
  of the request *and* the state of the authority at the moment of evaluation.
- Including it would mean the same request submitted twice against a **changed**
  authority had two different identities. That breaks replay and conflict
  semantics at the root: a changed authority producing a different winner is the
  *same request with a different outcome*, not a different request.
- The outcome belongs where it already is — in the `capability-selection` record
  (`selected_instance_id`, `considered_candidates`, `excluded_candidates`) and in
  that record's evidence (`causal_references` names the route and every
  candidate).

So: **request identity covers inputs; the record covers what was decided.** A
derived value is not put into request identity merely because it is useful
output. The preflight surfaces it in the CLI payload instead, where it is
reported without becoming part of the operation's identity.

Verified: the rehearsal and the write produce the *same* digest for the same
body, and a repeated rehearsal over an unchanged authority is byte-stable.

---

## 9. Deterministic selection and negative controls

Selection is deterministic by **canonical declared order**, not by scoring. That
rule was preserved exactly — no eligibility was loosened to make a preflight
succeed.

| Case | Result |
|---|---|
| one eligible candidate | rehearsal names it; write agrees |
| multiple eligible candidates | first in declared order, both paths (existing C6 matrix, unchanged) |
| deterministic tie/order behaviour | declared order is total; no tie-break exists (unchanged) |
| no eligible candidates | `selected_instance_id is None`, preflight outcome, nothing written |
| candidate removed by health input | `selected_instance_id is None`, nothing written |
| route mismatch / no route for class | `selected_instance_id is None`, nothing written |
| stale advertisement, expired instance, trust refusal, malformed candidate | judged by the same `_exclusions` / `evaluate_eligibility` path the write uses — the full existing C6 exclusion matrix runs unchanged and still passes |

```
PASS: a rehearsal whose only candidate is removed selects nothing
PASS: a rehearsal with no route resolves to no candidate
```

**A rehearsal reports a refusal as a refusal**, never as an acceptance —
`would_accept` is `false` and `rehearsal_outcome` carries the governed outcome.

### Replay semantics

| Case | Behaviour |
|---|---|
| identical preflight replay | stable digest and prediction over an unchanged authority; nothing written |
| identical committed request replay | **unchanged** — `EXACT_REPLAY`, original identity returned |
| same `request_id`, different body | **unchanged** — `CONFLICT`, `request_identity_conflict` |
| preflight *after* a committed write | still a preflight, not a replay — replay is not classified during a rehearsal |

```
PASS: a repeated rehearsal over an unchanged authority answers identically
PASS: a rehearsal after the write is still a preflight, not a replay
```

The last row is the subtle one and is asserted explicitly: a rehearsal reports
what a *new* write would decide, because there is no submitted operation to
replay against.

---

## 10. Fixture preflight/write equivalence

A complete temporary Fabric world built entirely through the released governed
operations — `CAPDEF`, `CCON`, `CPKG`, `CHOST`, `CADV`, `CINST`, `CROUTE`, with
the full Trust authority behind it (`c6_world`). A selection made over a store no
admission path could produce would prove nothing.

Sequence: **rehearse → capture → commit → compare.**

```
PASS: a rehearsed selection reports the preflight outcome
PASS: a rehearsed selection names no record
PASS: a rehearsed selection names the candidate declared order chooses
PASS: the committed selection is accepted
PASS: the committed selection takes the identity the rehearsal predicted
PASS: the committed selection chooses the candidate the rehearsal named
PASS: the rehearsal and the write share one request digest
PASS: the durable record names the rehearsed candidate
```

**Production remained untouched throughout** — every fixture runs in a temporary
root, and the suite's own backstop asserts it.

---

## 11. CLI behaviour

`--preflight` was added to the **existing** `select` command. No second verb:
choosing whether to rehearse is a flag on the operation, not a different
operation.

```
$ python3 -m tools.fabric.cli select --preflight \
    --store-root <root> --expected-uid <uid> --expected-gid <gid> \
    --input-file <body>.json --approved-directory <dir> \
    --trust-store-root <trust>
```

Both stores are opened read-only (`FabricStore.open_for_read`,
`TrustStore.open_for_read`), so asking whether the write would succeed cannot
provision what it is asking about.

Emitted payload:

```json
{
  "outcome": "preflight",
  "operation": "select",
  "would_accept": true,
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "record_kind": "capability-selection",
  "predicted_record_id": "CSEL-000001",
  "selected_instance_id": "CINST-000001",
  "destination": "<store>/capability-selections/CSEL-000001.yaml",
  "destination_exists": false,
  "store_root": "<store>",
  "store_exists": true,
  "request_id": "<governed request identity>",
  "request_digest": "sha256:…",
  "mutated": false
}
```

Every field name is the project's own. `selected_instance_id` is the whole
reason to rehearse a selection: an operator wants to know which binding would
serve *before* an identity is spent on finding out.

```
PASS: the select preflight command exits zero
PASS: a governed selection rehearsal raises no traceback
PASS: the command reports a non-mutating preflight
PASS: the command predicts the identity the store would allocate
PASS: the command names the candidate declared order chooses
PASS: the command reports the destination as absent
PASS: the command reports the governed request identity and digest
PASS: the select preflight command leaves the fabric byte-identical
```

Structured refusal only — a governed refusal exits 1 with a JSON payload, never
a traceback.

---

## 12. G11-B install-surface impact

**No change. No pinned digest required updating.**

Files changed by G11-C: `tools/fabric/admission.py`, `tools/fabric/cli.py`,
`tools/fabric/selection.py`, `tests/test-fabric-runtime.sh`.

All three source files are on the **`GENERATION_11_EXCLUDED`** list that G11-B
declared. The closure was **re-derived** after the change to be certain the new
`selection → admission` import had not widened it:

```
closure of tools.fabric.inspection after G11-C:
    tools.common.immutable_store   tools.fabric.models
    tools.fabric.errors            tools.fabric.request_identity
    tools.fabric.evidence          tools.fabric.store
    tools.fabric.identifiers       tools.fabric.validator
    tools.fabric.inspection

admission in closure: False    selection in closure: False    cli in closure: False
size: 9  (was 9 in G11-B)
```

Imports flow `selection → admission`, never the reverse, so a closure computed
from `inspection` downward is unaffected. The installed-only closure suite
re-ran and passed unchanged.

**Recorded as the brief asks:** *source correction required for governed
operator selection; not part of the installed Capability Runtime.* The G11-B
runtime dependency surface was **not enlarged** because selection changed.

---

## 13. Changed files and commit

**Implementation:** `6016d4f0b8cfea9bfc8f60166b7cba5a2fa82a75`
`feat(fabric): add read-only selection preflight`

```
 tests/test-fabric-runtime.sh | 151 +++++++++++++++++++++++++++++++++++++
 tools/fabric/admission.py    |  12 ++
 tools/fabric/cli.py          |  56 +++++++++++-
 tools/fabric/selection.py    |  65 ++++++++++----
 4 files changed, 269 insertions(+), 15 deletions(-)
```

### Validation, from the clean implementation commit

| Check | Result |
|---|---|
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh` | **PASS (full mode) — 93/93 steps** |
| `tests/test-fabric-runtime.sh` | **PASS** — full suite, 28 new assertions |
| `tests/test-fabric-runtime-install-closure.sh` | **PASS** — closure unchanged |

```
Validation passed (full mode), started 2026-08-26T19:18:23-05:00, 93/93 steps.
```

Full validation was mandatory here under the process rule accepted in G11-B
(§13 of that report), because repository `HEAD` changed in this checkpoint.

---

## 14. Production before / after

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric | `7780dacf…ab072` | `7780dacf…ab072` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifact | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |
| Installed generation | `CGEN-000000000001` | `CGEN-000000000001` | **UNCHANGED** |

```
CADV-000001  cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195  UNCHANGED
CSEL = 0     capability-selection.seq : absent
CINST = 0    CROUTE = 0    CADV = 1
Root Authority : unmounted
tools/fabric installed? NO — Generation 11 not installed
```

**No successful live selection preflight was attempted**, as instructed.
Production has no `CINST` and no `CROUTE`, so a live preflight could only have
succeeded by manufacturing production authority — which is exactly what the
brief forbids. Live checks proved only that `CSEL` is 0, the sequence is absent,
and production is unchanged. Successful select preflight lives in fixtures until
the prerequisite production objects legitimately exist.

---

## 15. Generation-11 readiness matrix

| Blocker | Status | Closed by |
|---|---|---|
| **G11-A1** mandatory advertisement identity | **CLOSED** | `c35ccd8c` |
| **G11-A2** effective target binding | **CLOSED** | `305f84aa` |
| **G11-A3** CADV supersession | **CLOSED** | `305f84aa` |
| **G11-B** installed read-only Fabric closure | **CLOSED** | `e9e6405e` |
| **G11-C** selection preflight | **CLOSED** | `6016d4f0` |

**All five known G11 source blockers are closed. No new blocker was discovered
in this checkpoint.**

**G11 source is ready.** That is a statement about *source closure only*. It
does **not** mean Generation 11 is installed, and it does not authorise
installation: the transactional installer has not been written, and installing
is a separate, independently authorised ceremony.

Two observations carried forward, neither a blocker:

- **`superseded_by`** remains legacy derived structure across all seven record
  classes — read by `selection.py` as a fallback, written by nothing (G11-A §7).
- **Temporal refusal granularity** — all invalid temporal relationships report
  `invalid-validity-window` (S5-B1 §6).

---

## 16. Actions explicitly NOT performed

- **Generation 11 not installed.** No installer written or run — the reviewer
  ruling explicitly deferred it to the installation ceremony.
- **Generation 10 not modified.**
- **No `CADV-000002`, no CINST, no CROUTE, no CSEL** created.
- **No live selection preflight attempted against production**, and **no
  production authority manufactured** to make one succeed.
- **No Fabric, Trust, Artifact or Platform Evidence mutation.**
- **No package staged. Nothing invoked. Root Authority not mounted.**
- **No eligibility loosened** to make a preflight succeed.
- **No separate preflight algorithm** written — the same `_decide` runs.
- **No second rehearsal context variable** introduced.
- **No derived value added to request identity** (§8).
- **G11-B install surface not enlarged** because selection changed (§12).
- **No unrelated cleanup mixed in.**
- **No secrets recorded.**

---

## 17. Recommended next checkpoint

**The Generation-11 installation ceremony.**

All five source blockers are closed and the reviewed surface is pinned. The
ceremony should:

1. Write the transactional installer against the reviewed commit, using the
   proven Generation-10 journal / prepared-copy / recovery model, consuming
   `provisioning/execution/generation-11-surface.sh`.
2. Rehearse it (`--verify`), then install under independent authorisation.
3. Prove the installed runtime is self-contained afterwards by re-running the
   installed-only closure suite against the **real** library root.

Then, in order:

4. **A fresh advertisement** — `CADV-000002 supersedes CADV-000001`, using the
   renewal path G11-A established. `CADV-000001` lapses at
   `2026-08-27T14:13:53-05:00`; nothing breaks when it does, but a CINST needs a
   fresh claim.
5. **`CINST-000001`** — the first instance admission, with all five blockers
   closed and both target-binding and advertisement-identity invariants enforced.
6. **`CSEL-000001`** — the first governed selection, now rehearsable before the
   identity is spent.

---

## 18. Questions requiring reviewer ruling

1. **Is `is_rehearsing()` the right shape for sharing rehearsal state?** The
   alternative — a `ContextVar` in `selection.py` — was rejected because two
   states agree until one is entered without the other, and the failure mode is a
   rehearsal that writes. It does make `selection` import `admission`, which the
   module docstring previously noted it was *not* downstream of.
2. **Confirm the request-digest boundary** (§8): inputs in request identity,
   the chosen candidate in the record and its evidence. Putting the winner in the
   digest would make the same request against a changed authority a different
   request.
3. **Is skipping replay classification during a rehearsal correct?** A preflight
   after a committed write reports what a *new* write would decide, not
   `EXACT_REPLAY`. This mirrors `admission._governed`, but it is worth an
   explicit ruling now that selection has a durable record to replay against.
4. **Confirm G11 source-ready does not imply install-ready** (§15), and that the
   installation ceremony remains separately authorised.

---

## Appendix A — commands executed

```bash
# Phase 0
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <each G11-A/B commit> HEAD
cat /var/lib/kyri/implementation-authority/current-generation
<whole-tree digests: fabric, trust, artifacts, evidence>

# Reconstructing the selection path
grep -n "select" tools/fabric/cli.py
sed -n '360,560p' tools/fabric/selection.py        # _commit, select_candidate, _decide, _write
grep -n "_REHEARSING\|def rehearsing\|PREFLIGHT" tools/fabric/admission.py

# RED
python3 -m tools.fabric.cli select --help
python3 -c "<select in WRITE_OPERATIONS / CREATED_KINDS>"
python3 -c "<selection imports rehearsal state? _commit unconditional? >"

# GREEN
bash tests/test-fabric-runtime.sh                  # 28 new assertions

# Install-surface impact
python3 -c "<re-derive the closure of tools.fabric.inspection>"
bash tests/test-fabric-runtime-install-closure.sh

# Validation, from the clean implementation commit
git diff --check ; tools/dev/run-shellcheck.sh
pre-commit run --all-files ; tools/dev/run-validation.sh   # 93/93
```

## Appendix B — the rehearsal boundary, stated once

```
select_candidate(store, trust_store, **body)
        │
        ├── validate every governed input          ── runs in both modes
        ├── compute the request digest             ── runs in both modes
        │
        ├── is_rehearsing()? ──── yes ──┐
        │                                │
        │                                ├── _decide(...)         ── the SAME path
        │                                │     _resolve_route
        │                                │     _chain_heads
        │                                │     _exclusions → evaluate_eligibility
        │                                │     first eligible in declared order
        │                                │     _write → _commit
        │                                │              └── probe construction
        │                                │              └── STOP. no allocate, no write
        │                                └── SelectionResult(PREFLIGHT, …, selected)
        │
        └── no ──── request_critical_section
                        replay_lookup → EXACT_REPLAY | CONFLICT
                        _decide(...)   ── the SAME path
                                 _write → _commit
                                          └── probe construction
                                          └── allocate_id, write
                    SelectionResult(ACCEPTED, …, record_id, selected)

One algorithm. One rehearsal state. The boundary is where allocation begins.
```
