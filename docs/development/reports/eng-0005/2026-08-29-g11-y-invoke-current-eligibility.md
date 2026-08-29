# ENG-0005 G11-Y — Invoke-Time Current Eligibility Revalidation

- Checkpoint: ENG-0005 G11-Y
- Date: 2026-08-29
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `2374e5485bb88cfc210df6b87855a6bb6c56fdc5`
- Host: `schai`
- Result: `ACCEPTED`

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `2374e5485bb88cfc210df6b87855a6bb6c56fdc5` — matched |
| Origin contains HEAD | yes |
| Worktree | clean |
| G11-X implementation `9300250` | ancestor of HEAD |
| G11-X report | `docs/development/reports/eng-0005/2026-08-28-g11-x-invocation-operation-authority.md` |
| Governed chain | `CADV-000003 → CINST-000002 → CROUTE-0002 → CSEL-000001`, intact |
| `CSEL-000001` selected | `CINST-000002` |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Generation 11 runtime | `80f9dee2…07b5f`, unchanged |
| Root Authority | unmounted |
| Kyri sudoers rules | 0 |

Production has a zero R17 tail (`CINST-000002.admitted_until ==
CADV-000003.valid_until`), so the current chain was never exposed to the defect
this checkpoint closes. The bridge still had to be made safe for any historical
selection, including records that do carry a tail.

Manifests captured before any work: Fabric structural 30, content 21, `/data/kyri` 27.

**Validation process rule observed.** No `pgrep -f 'run-validation.sh'` polling was
used. G11-X ended with that pattern producing a false "RUNNING" reading, because it
matches the polling shell's own command line. Every wait in this checkpoint is on a
PID captured at launch (`kill -0 "$PID"`), and the authoritative result is the
validator's own exit status and output file.

## 2. The reviewer's ruling, implemented

The invocation boundary now re-establishes the **current** eligibility of the
instance the historical `CSEL` names, using the released engine rather than a
special-case advertisement comparison.

```
CSEL historical decision
 → resolve selected CINST
 → G11-X four-dimension scope authority, including the explicit operation
 → evaluate CURRENT eligibility at requested_at, via C5
 → require eligible
 → stage
```

`CSEL` remains historical evidence. Selection is not re-run. The route is not
consulted, and a route-head change alone is not a refusal (§8).

## 3. Initial RED evidence

Captured before any implementation change:

```
PART 1 — the bridge asks for current eligibility, through a trust root
FAIL: verify_selected_evidence takes a trust root
FAIL: prepare_invocation takes a trust root

PART 2 — the current production shape is supported
TypeError: verify_selected_evidence() got an unexpected keyword argument 'trust_root'
```

New suite: `tests/test-capability-invoke-current-eligibility.sh`, 6 parts.

One RED assertion initially passed vacuously — it matched the word "eligibility" in
the module's prose rather than a call. It was tightened to
`"evaluate_eligibility" in source` before implementing, so the check tests what it
claims.

## 4. The R17 disagreement, reproduced against the released bridge

Before the change, with a fixture built entirely through released governance
operations — an advertisement lapsing at T1 and an admission running to T2 > T1,
selected while both were live:

```
advertisement lapses : 2026-08-01T16:00:00-05:00
admission lapses     : 2026-08-03T10:00:00-05:00
evaluated at         : 2026-08-01T17:00:00-05:00   (inside the tail)

Fabric evaluate_eligibility : eligible=False unmet=['ELIG-6']
CURRENT invoke bridge       : supported=True  reason=None

DISAGREEMENT: True
```

The two components disagreed about whether the binding could serve. That the
released write path still permits such an admission is why invoke-time
revalidation is required rather than optional (§17).

After the change, both refuse, and the bridge carries the Fabric's own reason:

```
the Fabric refuses on ELIG-6 in the tail (unmet=['ELIG-6'])
the bridge refuses in the tail too (selected-instance-no-longer-eligible)
the underlying Fabric reason is carried for audit (('advertisement-not-fresh',))
before the tail opens, both agree the binding is eligible
```

## 5. Implementation placement

The gate lives in `tools/capability/fabric_evidence.py::verify_selected_evidence`,
the last fully refusable point — before package staging, `CINV` allocation, durable
invocation evidence, launch authorisation, the privileged transition, and `execve`.

The full authority sequence, in the order refusals now occur:

| # | Gate | Refusal |
|---|---|---|
| 1 | operation supplied and usable | `operation-not-supplied` |
| 2 | selection resolves and named an instance | `selection-not-found`, `selection-recorded-no-instance` |
| 3 | selection chose the claimed instance | `claimed-instance-not-selected` |
| 4 | instance resolves, not superseded, admitted, window open | `instance-superseded`, `instance-not-admitted`, `admission-window-not-open` |
| 5 | **G11-X** scope: shape, capability, operation, classification, target | five dimension-specific reasons |
| 6 | package / contract / definition chain coherent | `claimed-package-not-bound`, `record-chain-incoherent`, … |
| 7 | contract effect class executable | `effect-class-not-executable` |
| 8 | **G11-Y** current eligibility at `requested_at` | `selected-instance-no-longer-eligible` |

### 5.1 Why eligibility runs last, not at the brief's step 5

The brief's conceptual sequence places current eligibility before the G11-X scope
authority, and permits retaining cheaper checks that logically precede it. Eligibility
is placed **last** instead, and the reason is worth stating because it is a deviation:

- It is by far the most expensive gate — it reads the package, contract, host, and
  advertisement, and asks C3 twice. Every cheaper structural refusal should win.
- Ordering it earlier **masked precise refusals**. Measured, not predicted: with
  eligibility ahead of the chain checks, `package-not-found`, `contract-not-found`,
  and six package-manifest tamper cases all collapsed into
  `selected-instance-no-longer-eligible`, losing the diagnostic that says what is
  actually wrong. Placing it last restored every one.
- Nothing is weakened. The hard requirements hold: an ineligible binding is refused
  before staging, before `CINV` allocation, before any lifecycle transition, and
  before any adapter or handoff could be reached.

## 6. Shared engine, not duplicated rules

The bridge calls the released `tools.fabric.eligibility.evaluate_eligibility`. It does
not restate ELIG-1..12 — pinned by assertion:

```
PASS: the bridge calls the released evaluate_eligibility rather than re-deriving the conditions
PASS: the bridge does not restate ELIG-1 itself
PASS: the bridge does not restate ELIG-7 itself
PASS: the bridge does not restate ELIG-12 itself
```

No layering problem existed: `eligibility.py` imports only `identifiers`, `models`,
`resources`, `trust_adapter`, and `trust.models`. It reaches neither admission nor
selection, so there is no cycle.

### 6.1 Two read-only surfaces, because the engine wants stores

`evaluate_eligibility(store, trust_store, …)` needs exactly two methods from each:
`list_records`/`read_record`, and `read`/`all_records`. Handing it real store objects
would have put record writing, identifier allocation, and the Fabric request lock
inside a module whose central promise is that it can reach none of them.

So it is handed `_FabricReader` — served entirely from C8's read-only inspection
surface, the same one the module already used — and `_TrustReader`, forwarding two
reads. Both are pinned to expose nothing else:

```
PASS: the fabric surface handed to C5 is exactly two reads
PASS: the trust surface handed to C5 is exactly two reads
PASS: _FabricReader exposes no write / allocate_id / request_critical_section
PASS: _TrustReader exposes no write / allocate_id
```

**A narrowed surface is only safe if it changes no answer.** That is asserted
directly, comparing the adapters against the real stores:

```
a healthy world: the adapters and the real stores agree exactly
                 (direct=True/[]  adapted=True/[])
a revoked host : the adapters and the real stores agree exactly
                 (direct=False/['ELIG-2'] adapted=False/['ELIG-2'])
```

Reasons match too, not just verdicts — including the engine's own
`trust-unreadable`, so nothing is quietly degraded into a vaguer refusal.

## 7. The request built from governed authority

Only values the governance records already carry are used. The caller supplies none
of them.

| Field | Source |
|---|---|
| `capability_id` | the selected `CINST` |
| `contract_id` | the selected `CINST` |
| `accepted_contract_versions` | `CSEL.request_class` |
| `data_classification` | `CSEL.request_class` |
| `evaluated_at` | the invocation's `requested_at` |

`operation` is deliberately **not** in the eligibility request — it is not part of
the Fabric request class, and G11-X owns it separately at the scope gate.

## 8. A route-head change is not an invoke refusal

Proved with a fixture in which a second binding is admitted, the route is superseded
to point at it, and the originally selected binding remains otherwise eligible:

```
PASS: a second binding is admitted (accepted/None)
PASS: the route moves to the second binding
PASS: the historical selection still verifies after the route moved
PASS: and the Fabric still calls the originally selected binding eligible
```

The bridge reads no route, and `evaluate_eligibility` has no route condition — ELIG-13
and ELIG-14 belong to selection, not eligibility. The invoke question is whether the
selected binding is still eligible, not whether the routing plane would choose it
again; answering the second would make invocation a second selection system.

## 9. Refusal vocabulary

| Constant | String |
|---|---|
| `REASON_INELIGIBLE` | `selected-instance-no-longer-eligible` |
| `REASON_TRUST_UNREADABLE` | `trust-store-unreadable` |

Current ineligibility is never collapsed into a malformed-record error. The engine's
own unmet reasons ride alongside on a new `eligibility_reasons` field of the verdict,
empty on every other outcome. Both are closed vocabularies — condition reasons like
`advertisement-not-fresh`, never record contents — so nothing leaks past the boundary.

An unreadable Trust store is reported separately: it is the operator's plumbing, not
a statement about the binding, and reporting it as ineligibility would blame the
record for the wrong thing.

## 10. Negative dynamic-state matrix

Every case built through released operations, and every one checked twice — what the
Fabric concludes, and what the bridge concludes:

| Case | Fabric | Bridge |
|---|---|---|
| Advertisement lapsed, admission still open (R17 tail) | ineligible, `ELIG-6` | `selected-instance-no-longer-eligible` |
| Admission window closed | ineligible | `admission-window-not-open` (cheaper gate first) |
| Host drained after admission, via `refresh_subject` | ineligible, `ELIG-12` | `selected-instance-no-longer-eligible` |
| Host standing revoked | ineligible, `ELIG-2` | `selected-instance-no-longer-eligible` |
| Host quarantined | ineligible, `ELIG-2`, `ELIG-10` | `selected-instance-no-longer-eligible` |
| Package standing revoked | ineligible, `ELIG-1` | `selected-instance-no-longer-eligible` |
| Package quarantined | ineligible, `ELIG-1`, `ELIG-11` | `selected-instance-no-longer-eligible` |
| Route moved to another binding | **eligible** | **supported** |
| Currently eligible binding | eligible | supported |

Each trust case also asserts the Fabric reason is carried through for audit.

Two method corrections made while building this matrix, recorded because both would
have produced falsely passing tests:

- The first draft built each fixture inside a `with TemporaryDirectory()` block and
  then evaluated it *after* the block exited. The directory was already deleted, so
  "the Fabric refuses" and "the bridge refuses" both passed for the trivial reason
  that a missing store is unreadable. Every case now runs inside its own live fixture.
- A host cannot be admitted onto while draining, so the fixture could not simply
  declare `availability_intent="draining"`. The world is built in service and drained
  afterwards through `refresh_subject`, the way an operator would.

### 10.1 One case that is not what the brief expected

The brief asks for a case where "the advertisement is no longer the current head"
refuses. It does not, and the engine is not wrong to allow it: `_advertised` (ELIG-6)
reads the advertisement the instance names and checks only
`observed_at <= instant < valid_until`. It performs no head-ness check. A superseded
advertisement that is still inside its own window therefore keeps its binding
eligible until it lapses.

Reported rather than papered over. If head-ness should gate eligibility, that is a
change to C5's ELIG-6 and belongs in its own RED-first checkpoint — inventing it here
would put a rule in the invocation boundary that the Fabric itself does not apply,
recreating exactly the disagreement this checkpoint removes.

## 11. G11-X regression

Every G11-X control is intact and re-asserted inside the new suite as well as its own:

```
PASS: an unpermitted operation still refuses for its own reason (operation-not-permitted-by-scope)
PASS: an absent operation still refuses for its own reason (operation-not-supplied)
PASS: a claimed instance the selection did not choose still refuses
```

`--operation` remains required with no default; the CSEL schema is untouched; the
operation remains in the invocation binding digest and the durable `CINV`; all four
scope dimensions are still checked before staging. `tests/test-capability-invocation-operation-authority.sh`
passes in full, run twice.

## 12. The production-shaped positive case

A fixture matching the production chain, at an instant inside the admission window,
with `operation = execute`:

```
PASS: the Fabric calls the binding eligible
PASS: the bridge supports a currently eligible binding (None)
PASS: a supported verdict names no refusal
PASS: verification wrote nothing
```

Nothing was staged, no adapter was reached, and no durable record was created.

## 13. Two architectural invariants the ruling changed

Both were real guards, both had to be narrowed rather than deleted, and neither was
worked around.

**`tests/test-capability-runtime.sh` — the capability-runtime import policy.** It
banned `eligibility` and `evaluate_eligibility` in a list headed "the released
decision and mutation surfaces", alongside `admit_instance`, `allocate_id`,
`write_atomic`, and `FabricStore`. But `evaluate_eligibility` is neither: by its own
contract it "writes nothing, allocates nothing, and remembers nothing". It was banned
by association. C5 eligibility now joins C8 inspection in `ALLOWED_FABRIC_IMPORTS`.
**`selection` stays banned** — asking whether a binding is still eligible is not
choosing one. A parallel `ALLOWED_TRUST_IMPORTS` admits only the read-only store
module, and a new `FORBIDDEN_TRUST_SYMBOLS` list keeps every Trust decision surface
unreachable by name.

**`tests/test-capability-execution-launch-cli.sh` — the CLI import pin.** Its comment
read: "tools.trust is banned, because nothing in the Capability Runtime may reach the
Trust plane." That is now false by ruling: eligibility includes trust standing and
quarantine, so a runtime that could not reach Trust at all could not ask whether a
revoked subject may still serve. The pin now names the Trust **decision** modules
individually and asserts none of them loads, so a new decision surface added later
fails here instead of widening what the runtime can reach.

A lazy import would have kept both assertions green while the runtime still reached
Trust at call time. That would have hidden the change from the tests written to catch
it, so the guards were narrowed to say what is actually true and required.

A third guard tripped on prose rather than behaviour: it is a substring check over the
whole file, and my `_FabricReader` docstring explained the design by naming
`FabricStore` and `allocate_id`. The docstring was reworded; the guard was not
weakened.

## 14. Regression results

| Suite | Result |
|---|---|
| `test-capability-invoke-current-eligibility.sh` (new) | PASS (twice) |
| `test-capability-invocation-operation-authority.sh` | PASS (twice) |
| `test-capability-runtime.sh` | PASS |
| `test-capability-fabric.sh` | PASS |
| `test-capability-execution-launch-bridge.sh` | PASS |
| `test-capability-execution-launch-cli.sh` | PASS |
| `test-capability-execution-g5-preflight.sh` | PASS |
| `test-fabric-preflight.sh` | PASS |
| `test-fabric-route-preflight.sh` | PASS |
| `test-fabric-advertisement-preflight.sh` | PASS |
| `test-fabric-instance-admission-integrity.sh` | PASS |
| `test-fabric-g11-integrity.sh` | PASS |
| `test-fabric-package-manifest.sh` | PASS |
| `test-fabric-runtime-install-closure.sh` | PASS |
| `test-trust-decision-preflight.sh` | PASS |
| `test-platform-model.sh` | PASS |
| `pre-commit run --all-files` | PASS |
| `shellcheck -S warning` on changed shell | clean |

### 14.1 Fixtures the change required

Three suites carried fixtures predating this boundary. Each now builds a **real**
Trust store through the released ceremony rather than hand-written trust records:
hand-writing them would be inventing the very evidence the new check exists to
consult. Their Fabric records gained what eligibility reads — an advertisement, the
two trust record identities, `satisfied_contract_versions`, resource profiles, and an
`evidence.approving_authority` (ELIG-7 asks *who approved* the admission, not merely
that a decision is named).

`provisioning/execution/g5-preflight.sh` had three declared delta rows refreshed to
the new checkout digests, using the multi-baseline mechanism added in G11-X.

## 15. Full validation

| Mode | Result |
|---|---|
| `run-validation.sh --quick` | **passed, 76/76 steps** |
| `run-validation.sh` (full) | **passed, 99/99 steps** |

Both totals re-measured from real runs: quick 75 → 76, full 98 → 99, because the new
suite runs in both modes. Registered in `tools/dev/run-validation.sh` and
`.github/workflows/ci.yml`.

**Authoritative completion method**: each validator was launched with its PID
captured, waited on with `kill -0 "$PID"`, and judged by its own exit status and
output file. No self-matching process pattern was used.

## 16. Production no-mutation proof

```
Fabric structural manifest : IDENTICAL
Fabric content manifest    : IDENTICAL
/data/kyri manifest        : IDENTICAL
installed runtime digest   : 80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b (unchanged)
CSEL count = 1   handoff entries = 0   Kyri sudoers rules = 0
```

Nothing staged, invoked, or launched. No Fabric record created or altered. Trust,
Artifact authority, and Platform Evidence untouched. Generation 11 not reinstalled;
Root Authority not mounted. The new suite carries its own production-path guard and
reports `no production path changed while this suite ran`.

## 17. ⚠ Neither G11-X nor G11-Y is active on this host

`NEW_GENERATION_REQUIRED_BEFORE_PRODUCTION_INVOKE = YES`.

The installed Generation-11 runtime remains `80f9dee2…07b5f`. Both corrections are
committed to the repository and **neither is installed**, so the enforcement
described here is not yet active production behaviour. `test-fabric-runtime-install-closure.sh`
continues to pass precisely because it exercises the installed bytes — the ones G11-W
audited.

The next generation must contain **both**:

- G11-X per-invocation operation and effective-scope authority;
- G11-Y invoke-time current eligibility revalidation.

One thing that generation's author needs to know: this change widens the capability
runtime's import closure. `fabric_evidence.py` now reaches `tools.fabric.eligibility`
and `tools.trust.store`, which transitively pull in `tools.fabric.resources`,
`tools.fabric.trust_adapter`, `tools.trust.query`, `tools.trust.scope`, and their
dependencies. The Generation-11 closure was computed from `tools.fabric.inspection`
alone; a Generation-12 installer must recompute it, and the object count will grow.

## 18. Structural dependency bound — follow-up, not implemented

`ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING = YES`.

`admitted_until <= advertisement.valid_until` was **not** added as an admission
invariant, per the ruling. It remains worth doing as defence in depth, but it would
not have replaced this checkpoint: historical records already carry tails, Trust
standing and quarantine change after admission, and an advertisement's currency can
change for reasons other than time. Invoke-time revalidation is required regardless.

## 19. Route-head hardening — carried forward

`NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING = YES`. `create_route` was not
touched; no route was created or modified. The G11-K non-head-predecessor gap remains
open and blocks the next route write.

## 20. Actions not performed

- Nothing staged, invoked, or launched; no adapter enabled; no `execve`.
- No new generation built or installed; runtime untouched; no sudoers installed.
- No Fabric record created or altered — `CSEL-000001`, `CINST-000002`, `CADV-000003`,
  and both routes are byte-identical.
- No Trust, Artifact authority, or Platform Evidence mutation; Root Authority not mounted.
- No route-head fix; no structural admission dependency bound.
- No second Trust evaluation algorithm — the bridge consumes whatever
  `evaluate_eligibility` consumes.
- No change to selection, the CSEL schema, or route equality.
- ELIG-6 head-ness not added (§10.1).
- No ENG-0006 work; no TrustGateway cutover.

## Appendix A — commands executed

```bash
# Preflight (read-only)
git rev-parse HEAD; git status --porcelain
git merge-base --is-ancestor 9300250 HEAD
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# RED first, then the disagreement reproduced against the released bridge
bash tests/test-capability-invoke-current-eligibility.sh          # failed, as designed
python3 <scratchpad>/g11y-disagree.py                             # Fabric False, bridge True

# Implementation: fabric_evidence (adapters, gate, reasons), coordinator, cli
# Fixture upgrades: capability-runtime, invocation-operation-authority, launch-cli
# Declared delta refreshed in provisioning/execution/g5-preflight.sh

# Verification
bash tests/test-capability-invoke-current-eligibility.sh          # twice
bash tests/test-capability-invocation-operation-authority.sh      # twice
bash tests/test-capability-runtime.sh
bash tests/test-capability-execution-{launch-bridge,launch-cli,g5-preflight}.sh
bash tests/test-fabric-{preflight,route-preflight,advertisement-preflight}.sh
bash tests/test-fabric-{instance-admission-integrity,g11-integrity,package-manifest}.sh
bash tests/test-fabric-runtime-install-closure.sh
bash tests/test-trust-decision-preflight.sh tests/test-platform-model.sh
shellcheck -S warning <changed shell>
pre-commit run --all-files

# Validators, waited on by captured PID and judged by exit status
bash tools/dev/run-validation.sh --quick & QUICK_PID=$!   # 76/76
while kill -0 "$QUICK_PID" 2>/dev/null; do sleep 10; done
bash tools/dev/run-validation.sh & FULL_PID=$!            # 99/99
while kill -0 "$FULL_PID" 2>/dev/null; do sleep 20; done
```

## Appendix B — the boundary, after this checkpoint

```
CSEL-000001  selected CINST-000002 via CROUTE-0002   (historical; no operation)
      │
      │  capability invoke --operation execute --trust-store-root …
      ▼
verify_selected_evidence
      ├─ operation named                          operation-not-supplied
      ├─ selection resolves and chose this CINST  claimed-instance-not-selected
      ├─ admitted, not superseded, window open    admission-window-not-open
      ├─ G11-X scope, four dimensions             …-not-permitted-by-scope
      ├─ package / contract / definition coherent record-chain-incoherent
      ├─ effect class executable                  effect-class-not-executable
      └─ G11-Y CURRENT eligibility, asked of C5   selected-instance-no-longer-eligible
             ├─ ELIG-1/2   trust standing            + the engine's own reasons
             ├─ ELIG-6     advertisement fresh         carried for audit
             ├─ ELIG-7     admission open
             ├─ ELIG-10/11 quarantine
             ├─ ELIG-12    host in service
             └─ (no route condition — a moved route is not a refusal)
      ▼
resolve_and_stage_package → CINV → launch → execve
```
