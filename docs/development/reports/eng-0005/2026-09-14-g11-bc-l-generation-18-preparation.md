# ENG-0005 G11-BC-L — Generation 18, prepared

**Checkpoint:** G11-BC-L (preparation only)
**Date:** 2026-09-14
**Branch:** `arch/eng-0005-execution-transition`
**Reviewer rulings carried in:** `G11_BC_K_ACCEPTED=YES`,
`GENERATION_18_DECLARATION=ACCEPTED`, `GEN18_BEFORE_FABRIC_RENEWAL=YES`

Generation 18 is **not installed**. The host remains at Generation 17 and still
carries the defect. Nothing was written to Fabric, Trust, the runtime store, the
handoff, sudoers or the image.

Two objects, one coherence group, and a publication order that is **not**
Generation 17's and was measured rather than inherited.

---

## 1. The Generation-17 predecessor, reconstructed

Three independent durable sources, all agreeing:

| source | `evidence.py` | `coordinator.py` |
| --- | --- | --- |
| installed bytes on the host | `25f65bd3…8588b8` | `b72e7e25…8603c0` |
| the reviewed `g5-preflight` declaration, last baseline entry | `25f65bd3…8588b8` | `b72e7e25…8603c0` |
| the repository at the Generation-17 authority `15a8c738…` | `25f65bd3…8588b8` | `b72e7e25…8603c0` |

A full comparison of all 46 installed modules under
`/usr/lib/kyri/python/tools/capability/` against the repository at G11-BC-K found
**exactly two** differences — the two this generation moves. The overlays the
successor-aware verifier needs are the three accepted helper ceremonies
(§4.1); the installed library count is 81, which is the declared 80 plus the one
library-root object those ceremonies created.

```
GEN17_PREDECESSOR_PROOF=PASS
```

Not from the checkout alone: the checkout is one of the three sources and the
other two are the installed host and a reviewed declaration written before this
checkpoint existed.

---

## 2. The coherence set

**The framework requires a group identifier.** Field 6 of every `MATRIX` row is
a group letter; `matrix_groups` derives the distinct set and
`require_group_coherence` refuses a group that is split across baseline and
target. It is a mandatory column, not an optional label.

**The letters are a per-installer mnemonic vocabulary, not a global registry.**
Generations 13–14 used A/B/C (`A` = execution and supervision, `C` = identity,
recovery and readiness); Generation 15 introduced V/R/H with different meanings
and Generation 17 reused `A` for the container-runtime binding. Each letter is an
initial for the capability it names: **V** erification surface, **R** ecovery
discovery, **H** elper declaration, container-runtime binding (**A**).

So the identifier is derived from that convention, not invented as a sequence
position:

```
COHERENCE_IDENTIFIER=T   ("the terminal-result authority")
COHERENCE_MEMBERS=
  tools/capability/evidence.py
  tools/capability/coordinator.py
```

`T` is unused across Generations 13 to 17. (The review package's "group G" was a
next-letter guess and is not used.)

### 2.1 Why these two belong together, from the invariant

`coordinator.py` imports `require_no_terminal_result` from `evidence.py` **at
module load**, and `evidence.py` is its only definition. Neither object is a
valid complete Generation 18 alone, and the two failures are different in kind:

- `coordinator.py` at 18 with `evidence.py` at 17 → `ImportError` on every
  `tools.capability.cli` command.
- `evidence.py` at 18 with `coordinator.py` at 17 → imports fine, and defines a
  gate nobody calls. **A host that looks corrected and is not.**

The second is the dangerous one, because nothing announces it. That is precisely
what a coherence group exists to refuse, and the suite proves both by importing
each mix rather than by reading the matrix back.

### 2.2 A defect found in the accepted Generation-17 installer

Generation 17's matrix carries a row in group `A`, and its `group_name()` has no
case for `A` — so a split in that group would report **"unknown group A"**, the
exact failure its own comment says the names exist to prevent:

> *"a coherence failure naming 'unknown group V' would be a worse report than one
> naming what V is."*

Diagnostic only, and in an accepted shipped installer, so it is **reported, not
edited**. Generation 18 does not repeat it: `group_name()` now carries `A` and
`T`, and a new `require_group_names_known` refuses any matrix letter without a
name — checked in `--verify-source` and asserted by the suite.

---

## 3. Publication order

Both orders were evaluated by importing `tools.capability.cli` against **all
four** mixes. Generation 17's reasoning — the readiness authority closes
execution first — **does not transfer**, because nothing in this matrix is a
readiness authority and nothing here closes execution. Inheriting it would have
been the defect.

| `evidence.py` | `coordinator.py` | observed |
| --- | --- | --- |
| 17 | 17 | gate not called; record guard fail-open — the accepted Generation-17 baseline |
| **18** | 17 | gate not called; record guard **hardened** — **order A intermediate** |
| 17 | **18** | `ImportError: cannot import name 'require_no_terminal_result'` — **order B intermediate** |
| 18 | 18 | gate called; record guard hardened |

| question | order A (evidence first) | order B (coordinator first) |
| --- | --- | --- |
| old behaviour reachable? | yes — Generation-17 behaviour | no; nothing runs |
| caller referencing an unavailable reader? | no | **yes** |
| execution open or closed? | open, and safe | closed, but by breakage |
| import/runtime failure? | none | **every CLI command fails** |
| duplicate-result safety weakened? | **no — strengthened**: the hardened recording guard is already in place | not weakened, but unreachable |

Order A's only intermediate is **strictly safer than the accepted status quo**.
Order B's breaks `recover` — the one command an operator needs to resolve an
interrupted transaction — so it is fail-closed in a way that removes the
recovery surface.

```
GEN18_PUBLICATION_ORDER=tools/capability/evidence.py, then tools/capability/coordinator.py
PARTIAL_PUBLICATION_FAIL_CLOSED=YES
```

`require_fail_closed_first` holds it as a checked property (row one is the
defining module, row two the importing module, both in group T), and `rollback`
restores in **reverse** — `coordinator.py` back first — so the ImportError state
is unreachable from either direction. The suite drives a reordered copy of the
installer and requires the refusal by name.

---

## 4. The installer

**`provisioning/execution/install-generation-18.sh`** — shellcheck clean, modes
`--verify-source`, `--verify`, `--install`, `--verify-installed`, `--recover`,
plus `--fixture` for the suite.

Its own namespace, colliding with nothing:

```
TRANSACTION_ROOT   /root/kyri-gen18-transaction
PREPARED_SUFFIX    .kyri-gen18.new
BACKUP_SUFFIX      .kyri-gen18.gen17
TRANSACTION_ID     gen18-<utc>-<pid>
evidence written   /root/kyri-gen18-library-digests.txt
                   /root/kyri-gen18-helper-digests.txt
baseline read      /root/kyri-gen17-library-digests.txt
                   /root/kyri-gen17-helper-digests.txt
```

### 4.1 Inherited constants, audited rather than assumed

Deriving an installer from its predecessor is how this project builds each
generation, and it is also the source of a defect class that has now recurred
four times. Every generation-keyed constant was enumerated and decided:

| constant | inherited value | corrected to | why it mattered |
| --- | --- | --- | --- |
| `COMMIT` | `15a8c738…` (Gen17 authority) | `88a1e484…` (G11-BC-K) | survived the numeric rename as hex |
| `GEN17_COMMIT` | `91cb1b60…` (Gen16 authority) | `15a8c738…` | same |
| `CEREMONIES_BEFORE_THIS_GENERATION` | ax, bb | ax, bb, **bc-e** | G11-BC-E has been accepted since |
| `CEREMONIES_AFTER_THIS_GENERATION` | bc-e | **empty** | no ceremony follows this generation |
| `FAIL_CLOSED_FIRST` | `helpers.py` | `evidence.py` | different property entirely |
| "this generation SHUTS readiness" | inherited argument | rewritten | **false here** — §4.2 |
| "publishes three objects" | inherited | two | — |
| closure comment naming helpers/podman/launcher | inherited | evidence/coordinator | — |

### 4.2 The safety argument that could not be inherited

Generation 17 permitted the sudoers grants to be present during its transaction
because *"readiness closes"*. That is not true here, and copying it would have
been an argument that sounds right and protects nothing.

The Generation-18 argument is the publication order instead: a Python process
loads its modules once at start, so an execution racing the transaction sees one
consistent set. Because `evidence.py` publishes first, the only mixed set a
starting process can observe is new-evidence/old-coordinator — Generation-17
behaviour with a hardened recording guard. The unsafe mix is unreachable going
forward and unreachable on rollback.

`report_execution_readiness` now says so directly, including that an
`incompatible` verdict after this ceremony is a **fault**, not an expected
intermediate — because an operator who remembers Generation 17 would otherwise
read an unchanged `compatible` as a check that failed to run.

---

## 5. Source authority

```
COMMIT=88a1e484f063ad0c4bb5d05ddac6de2df623491c
```

`--verify-source`, run against the committed tree, reads no installed path:

```
ok  repository at arch/eng-0005-execution-transition, reviewed authority
    88a1e484… present and an ancestor of HEAD
ok  2 Generation-18 source objects match the reviewed commit 88a1e484…
ok  the import closure of tools.capability.cli … closes over the declared
    surface (73 modules)
ok  no matrix row names a helper, a grant or a deployment identity:
    14 privileged objects are outside this ceremony
ok  the defining module publishes first and the importing module second,
    both in group T
ok  0 coherence-group carryover(s) verified
ok  every coherence group in the matrix has a name (T)
ok  the reviewed coordinator asks at line 260 and executes at line 262
ok  the locally executed path is gated at line 166, ahead of line 172
ok  the reviewed evidence.py carries one shared reader and no attempt_number fail-open
ok  the gate and the recording guard answer through the same reader

Generation 18 source verification: all checks passed.
2 object(s) would change (2 REPLACE, 0 CREATE).
```

**The correction is proved as ORDER, not as the presence of a word.** A grep for
`require_no_terminal_result` would pass on a coordinator that called it *after*
`supervisor.execute` — which is the defect. So both call sites are located by
line number and compared. The same check exists for the locally executed adapter
path.

No undeclared runtime object can be published: the closure check refuses any
matrix row the closure does not require, and the surplus check refuses any
installed object no accepted ceremony governs.

---

## 6. Preinstall verify

`--verify` proves, before anything is staged: host at Generation 17 with both
targets at exactly the predecessor digests; no target residue; no Generation-18
transaction in progress; the object count is the declared 80 plus the helper
ceremonies' creations; Fabric, Trust and sudoers unchanged; helper compatibility
`compatible` with 0 blocking; both execution grants present and pinning the
bytes this host carries; the verification grant absent.

Run unprivileged it halts cleanly and truthfully at the first thing it cannot
read:

```
STOP: the Generation-17 library evidence at /root/kyri-gen17-library-digests.txt is missing
```

**It does not depend on Fabric eligibility.** Generation 18 is a runtime safety
deployment, not an invocation decision; the expired advertisement is irrelevant
to it and is not consulted.

---

## 7. Transaction design

Staging and publication are same-filesystem (`require_same_filesystem`), atomic
`rename`, `sync_path` after each. Every irreversible step is journalled:
`PREPARING` → `PREPARED` → `COMMITTING` → `COMMITTED` → `VERIFIED` → `EVIDENCE`
→ `COMPLETE`, with `ROLLING_BACK` on failure.

| | `tools/capability/evidence.py` | `tools/capability/coordinator.py` |
| --- | --- | --- |
| operation | REPLACE | REPLACE |
| predecessor | `25f65bd345efc84faadfefff635d50b850df9362ae20130f47b55fc9cf8588b8` | `b72e7e2576095c96ffd5b4a3a48acc2fed7c1852b631a5f6f7d691e0bf8603c0` |
| target | `a571ad02ace56dbb93a5cc9385a4b2cca4e5c1922fa16bfa9f59848a25a386f6` | `acb80cb93084b2b196d6b806b278128458be8947a9575eac7c7c509e9f045585` |
| mode | 0444 | 0444 |
| owner | root:root | root:root |
| coherence | **T** | **T** |
| order | published **first** | published **second** |

Rollback restores from the retained predecessor copies in reverse order and
refuses to restore a retained file that is not the declared baseline. `--recover`
resolves an interrupted run from the journal.

---

## 8. Interruption matrix

Ten injection points, each on a fresh fixture:
`stage, staged, prepared, precommit, committing, publish, verify, postcommit,
evidence, cleanup`.

At every point the suite requires: the object count unchanged (this generation
creates and removes nothing); no transaction residue except at `cleanup`, where
exactly the artefacts cleanup removes are present; every row at one of its two
declared digests and never between; and a rollback that reaches the **exact**
Generation-17 library, compared by full manifest rather than by digest spot-check.

**The property that matters is not Generation 17's.** That suite required
execution to be CLOSED unless the state was complete; nothing here closes
execution, so inheriting it would test a property this generation does not have.
What is measured instead:

- `tools.capability.cli` must still **import** at every interruption point — the
  one state that breaks it is old-evidence/new-coordinator, and order plus
  reverse rollback make it unreachable.
- helper compatibility must be unchanged at `compatible` at every point.

```
UNSAFE_MIX_REACHABLE=NO across every interruption point
```

Nothing is guessed from installed bytes where the journal states the fact.

---

## 9. Negative controls

The suite drives refusals for: a wrong predecessor on either object; a target
already at the successor digest; undeclared runtime drift; an existing
transaction root; an existing journal; staging residue; a wrong source digest; a
wrong owner or mode; a carryover colliding with a matrix row; a reordered matrix;
a partial publication without a matching journal; Fabric or Trust privileged-
surface drift; the verification grant present; a grant pinning bytes the host
does not carry; an undeclared Kyri grant; an ungoverned extra library object; a
missing accepted object; and a superseded helper-ceremony state.

**104 assertions, all passing**, in
`tests/test-capability-execution-generation18-installer.sh`.

---

## 10. The invariant, against the installed fixture

Everything above proves the right bytes land. This proves the bytes **do the
thing** — driven through the fixture's own `tools.capability` after `--install`,
so it is the deployed library answering:

```
execute(CINV-000002) with CRES-000001 present
  -> TerminalResultExists, naming CRES-000001
  -> boundaries reached: NONE
execute(CINV-000003) with no terminal result
  -> passes the gate through to the launcher
```

The recording stub's methods stand for helper launch, transition action,
container creation, provider start and handoff ownership transfer; reaching any
of them is the failure. A control case proves the **Generation-17** fixture
library does *not* gate, so the case above measures this generation rather than
passing vacuously.

```
DUPLICATE_RESULT_PREEXEC_GATE_GEN18=PASS
```

---

## 11. CRES semantics preserved

Generation 18 does not reinterpret CRES-000001. The installed-fixture case above
re-reads the record after the gate fires and requires `outcome_class:
provider-error`, `result_digest: null`, `result_artifact_reference: null`,
`attempt_number: 1` — unchanged. `succeeded=false` and `disposal_proven=true`
are supervision facts and nothing in `supervision.py` moves.

No migration, no backfill, no record rewritten.

---

## 12. Host-coupled succession sweep

The class has bitten five times. Swept before installation, as required.

**The discriminator is where a suite gets its BYTES.** A suite that takes only
the PATH SET from the live runtime is unaffected: Generation 18 creates and
removes nothing. A suite that copies live bytes and rewinds successors is
affected the moment those bytes move — and Generation 18 moves two objects **no
ceremony since Generation 13 has touched**, which is exactly the case the
succession library's own doctrine warns about:

> *"a rewind list must name every ceremony accepted after the generation being
> reconstructed, or a successor touching an object no earlier ceremony touched
> would leave the fixture silently carrying that successor's bytes while claiming
> to be this host."*

| suite | classification | action |
| --- | --- | --- |
| `test-capability-execution-generation14-installer.sh` | **NEEDS_GEN18_SUCCESSOR** | rewind list `…-17` → `…-18` added |
| `test-capability-execution-helper-ceremony.sh` | **NEEDS_GEN18_SUCCESSOR** | rewind list `…-17` → `…-18` added |
| `test-capability-execution-generation13-packaging.sh` | **NEEDS_GEN18_SUCCESSOR** | three lists, all ending at `…-17`, extended |
| `test-capability-execution-generation12-packaging.sh` | **NEEDS_GEN18_SUCCESSOR** | successor list extended |
| `test-capability-execution-generation15/16/17/18-installer.sh` | SAFE | bytes from `git archive <predecessor>`; only the path set and object count come from live, and neither moves |
| `test-capability-execution-bb/bc-e-helper-ceremony.sh` | SAFE | same — path set live, bytes from a named commit |
| `test-capability-execution-g5-preflight.sh` | SAFE | reads the declaration, which G11-BC-K already updated |
| every other generation suite | HISTORICAL_ONLY | reasons about committed matrices, reads no live byte |

`generation13-packaging` was the sharp one: Generation 13's declared targets for
these two objects are `25f65bd3…` and `b72e7e25…` — **exactly the digests
Generation 18 replaces** — and no successor in its lists declares them. It would
have gone red the moment Generation 18 installed.

**No digest was bumped to match the live host.** Four successor lists gained one
ceremony name each. All four suites pass today, where the addition is a no-op
because the host is still at Generation 17, and they will be correct afterwards.

---

## 13. The operator ceremony

Committed at **`provisioning/execution/gen18-operator-ceremony.txt`** and
executed against a stub installer by the suite, so the control flow is proven
rather than described: `set -Eeuo pipefail` in the first lines, the journal and
residue refusals before any installer runs, the predecessor evidence checked,
and the four modes chained so any refusal stops everything. See the RETURN block
for the exact text.

No Fabric write, no CINV allocation, no execute, and no automatic `--recover`
after success.

---

## 14. Expected post-install state

| | expected |
| --- | --- |
| `HOST_GENERATION` | **18** |
| `tools/capability/evidence.py` | `a571ad02ace56dbb93a5cc9385a4b2cca4e5c1922fa16bfa9f59848a25a386f6`, `0444 root:root` |
| `tools/capability/coordinator.py` | `acb80cb93084b2b196d6b806b278128458be8947a9575eac7c7c509e9f045585`, `0444 root:root` |
| helper compatibility | `compatible` — **unchanged** |
| blocking | 0 — unchanged |
| `supervision_ready` | true — unchanged |
| library object count | 81 (80 declared + 1 helper-ceremony creation) — unchanged |
| CINV-000002 | `923ff0d7…` unchanged |
| CRES-000001 | `18ba4c34…` unchanged |
| CINV / CRES sequence | 2 / 1 |
| Fabric / Trust / sudoers | unchanged |
| `kyri-CINV-*` container | none |
| new evidence | `/root/kyri-gen18-library-digests.txt`, `/root/kyri-gen18-helper-digests.txt` |

An `incompatible` verdict would be a **fault**, not an expected intermediate.

---

## 15. The Fabric renewal candidates

```
BCJ_CANDIDATES_STILL_USABLE_AFTER_GEN18=NO — regenerate before any freeze
```

Measured, not judged by eye:

```
now                2026-09-14T14:27:51-05:00
chain observed_at  2026-09-13T19:00:00-05:00
chain valid_until  2026-09-17T19:00:00-05:00
window total       4 days
already elapsed    19h 27m
remaining          3 days 4h 32m
```

The bodies are still **structurally valid** — every instant in them is a literal,
so the digests have not decayed and `observed_at <= recorded_at < valid_until`
still holds. But nearly a fifth of the lease has already been spent sitting
unused, and the ordering ruling puts a Generation-18 deployment *and* its
acceptance checkpoint in front of them. Every hour of that comes out of the same
window, and if acceptance slips past 2026-09-17T19:00 the chain expires with
CINV-000003 mid-flight.

This is the risk flagged at G11-BC-J §0, now partly realised. The reviewer's own
instruction is not to force a nearly-expired candidate through because its digest
was previously reviewed, so: **regenerate the four bodies at freeze time**, with
`observed_at` anchored then. The work is mechanical — the shapes, the request
ids, the scope and the refusal digests are all settled; only the four instants
and therefore the four digests change.

---

## 16. Production non-mutation

| | required | measured |
| --- | --- | --- |
| `HOST_GENERATION` | 17 | 17 — `evidence.py` still `25f65bd3…`, `coordinator.py` still `b72e7e25…` |
| Generation 18 installed | NO | NO |
| `CINV-000002.yaml` | `923ff0d7…` | unchanged |
| `CRES-000001.yaml` | `18ba4c34…` | unchanged |
| CINV / CRES sequence | 2 / 1 | 2 / 1 |
| Fabric aggregate | — | `3fa32b83…` unchanged |
| Trust aggregate | — | `53605e4e…` unchanged |

No Fabric write, no Trust write, no CINV-000003, no CRES-000002, no `execute`,
no `recover`, no runtime mutation, no helper mutation, no sudoers mutation, no
Podman call. Every installer run was either `--verify-source` (reads no
installed path) or `--fixture`-bound.

---

## 17. Next

Reviewer accepts this preparation → the operator runs the §13 ceremony →
post-install acceptance checkpoint → **regenerate the G11-BC-J Fabric bodies**
(§15) and only then freeze them → CINV-000003 Stage 1 with the Option B payload
`be85d58f…`.

Still prepared and unauthorised, independent of all of this: the G11-BC-G
evidence remediation.
