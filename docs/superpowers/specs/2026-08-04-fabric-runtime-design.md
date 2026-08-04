# Fabric Runtime Design (ENG-0004)

> **This document specifies architecture and scope only. It authorises no
> implementation.** No runtime source, scaffolding, executable schema, or
> runtime test accompanies it. ENG-0004 implementation begins only when this
> specification is accepted and its own test-first plan, feature branch,
> review, and release boundary exist.

Refines [ADR-0012](../../decisions/ADR-0012-distributed-capability-fabric.md)
at its one documented unresolved boundary. It changes no accepted decision.

## 1. Purpose

ADR-0012 specifies the Distributed Capability Fabric as architecture and
deliberately builds nothing. The [engineering
ledger](../../history/v1.0-engineering-ledger.md) assigns the runtime to
ENG-0004 and its exit gate reads only *"Runtime implemented and validated in
reviewable increments."*

That left one question unanswered, and both the ledger and the [post-root
runtime sequence](../plans/2026-08-03-post-root-runtime-sequence.md) said so
explicitly: **ENG-0005's exact boundary against ENG-0004 was not yet
specified, and had to be settled before implementation began.**

This document settles it, and defines what ENG-0004 must deliver.

## 2. Entry gate

ENG-0004's entry gate is **Gate 1**, defined in [fabric governance
boundaries](../../fabric/governance-boundaries.md). All three conditions are
satisfied:

| Condition | Evidence |
|---|---|
| Operator Root Authority ceremony complete | `TAUTH-000001`, established out of band by a human |
| ENG-0001 released | `v0.9.7` |
| ENG-0002 released | `v0.9.8` |

**Gate 1 permits construction only.** It does not permit production operation.
Gate 2 — the TrustGateway production cutover gate — is separate, unchanged, and
still closed. Collapsing the two is the specific error the governance document
exists to prevent: a node admitted while the gateway still answers from
code-owned policy is trusted through a chain that does not terminate at the
root.

## 3. The ENG-0004 / ENG-0005 boundary

**Accepted decision.** This section records the architectural decision supplied
to close ADR-0012's documented gap. It refines the accepted architecture at
that boundary and alters ADR-0012, ADR-0013, `CAP-0000`, Gate 1, and Gate 2 in
no respect.

The controlling distinction:

> **ENG-0004 determines whether an already-described instance is governed,
> eligible, and deterministically selectable. ENG-0005 makes that instance
> executable and performs the capability invocation.**

### ENG-0004 owns the generic, capability-agnostic Fabric foundation

- Fabric record storage and validation
- The Fabric-known records for contracts, packages, hosts, advertisements,
  instances, and route/selection outcomes
- Governed host, advertisement, and instance admission
- Legal lifecycle transitions for Fabric-owned state
- Trust verification through released Trust Plane interfaces
- Deterministic eligibility calculation
- Deterministic selection from eligible candidates
- Read-only inspection and validation
- Fabric audit evidence
- Synthetic fixtures and isolated test stores
- The one-directional Health input boundary: Health may remove a candidate and
  may never add one

### ENG-0005 owns capability semantics and execution

- Loading or activating capability packages
- Binding admitted Fabric instances to executable capability code
- Capability invocation and execution
- Capability-specific lifecycle behaviour
- Capability input/output processing
- Capability-specific policy and validation
- Execution adapters, workers, dispatchers, and provider connectors
- Model/provider routing, token budgets, secret brokering, and OmniRoute-derived
  behaviour

### Consequences, stated so they cannot be read either way

- **Instance admission belongs to ENG-0004.**
- **Deterministic candidate selection belongs to ENG-0004.**
- **Capability activation and execution belong to ENG-0005.**
- ENG-0004 selection returns **only a Fabric identity or route/selection
  record. It must never invoke a capability.**
- A capability-package record in ENG-0004 is **governed metadata only**.
  ENG-0004 must not load or execute package contents.
- Health is an **optional** candidate-removal input boundary. ENG-0004 must not
  evaluate health, and must remain fully testable without Health Runtime.
- Production use remains prohibited until Gate 2.
- All runtime behaviour is developed and validated against **isolated synthetic
  fixtures only**.

This is the same seam ADR-0012 already draws in its own words — *"the core
carries no capability semantics… it never knows what a capability does."*
ENG-0004 builds that core. ENG-0005 supplies the semantics the core refuses to
hold.

## 4. Goals

1. Persist and validate the Fabric-owned records ADR-0012 defines, under the
   same append-only, write-once guarantees the Trust Plane already enforces.
2. Admit hosts, advertisements, and instances through a governed path where the
   default is ineligible and absence of a record is never permission.
3. Compute eligibility as a deterministic, total, explainable function of
   ADR-0012's eight conditions.
4. Select deterministically from eligible candidates in the human-declared route
   order, and record why every excluded candidate was excluded.
5. Verify trust exclusively through released Trust Plane interfaces, adding no
   trust domain and no trust semantics.
6. Produce audit evidence sufficient to answer, from records alone, *"why did
   this run there?"* and *"what was this machine allowed to do in March?"*
7. Remain inspectable and validatable read-only, repairing nothing.

## 5. Non-goals

Out of scope for ENG-0004, each because it belongs elsewhere:

| Excluded | Owner |
|---|---|
| Capability activation, invocation, execution | ENG-0005 |
| Execution adapters, workers, dispatchers, provider connectors | ENG-0005 |
| Model/provider routing, token budgets, secret brokering | ENG-0005 |
| Package loading or content interpretation | ENG-0005 |
| Health evaluation, health states, degradation semantics | ENG-0006 / ADR-0013 |
| Production node admission, registration, routing, selection, execution | Gate 2 / ENG-0003 |
| TrustGateway cutover | ENG-0003 |
| Scheduler, placement, clustering, leases | Unassigned; ENG-0007 / ENG-0008 |

## 6. What ADR-0012 already decides, and this specification does not revisit

The following are settled architecture. ENG-0004 implements them; it does not
reopen them.

**Trust domains.** The fabric uses `capability-package` and `fabric-node`,
reserved by ADR-0011 for exactly this release, and **adds none**. An
advertisement is not a trust subject at all — a self-report never becomes
trusted.

**Directionality.** Trust flows one way and terminates outside the platform:
Operator Root Authority → Trust Authority → Trust Decision → Trust Record →
instance eligibility → route → selection. Nothing flows back up. No execution
result, health signal, advertisement, latency measurement, or model output may
produce, raise, or restore a trust state.

**The eight eligibility conditions.** An instance is eligible only when all
eight hold: package trusted for the contract; host trusted as a fabric node;
package declares the requested contract version; host's *verified* resource
profile satisfies the package's declared requirements; a fresh advertisement
inside its validity window; a human-approved, unexpired admission decision; a
non-empty effective scope intersection; and a request data classification within
the host's ceiling. Any one missing makes the instance ineligible.

**Routing.** Deterministic, total, explainable. Resolve route (no route →
refuse) → reduce to eligible → allow health to remove → select first remaining
in declared order → refuse naming every exclusion if none remain → write a
selection record. `locality` is enforced, not advisory: a `local-only` request
must refuse rather than leave the host.

**Immutability.** Every advertisement, admission decision, selection, loss,
refusal, and supersession is immutable, append-only, and superseded rather than
edited.

**The fourteen prohibitions.** ADR-0012's "Explicitly forbidden" list stands
whole: no automatic node registration, no trust on first advertisement, no
self-admission, no peer discovery, no load/latency/score-based or weighted
routing, no automatic failover outside the declared candidate list, no automatic
remediation, no automatic trust change in either direction, no prediction, no
quorum/leader election/consensus/shared cluster state, no capability inference
from behaviour, no credential material in any fabric record, and no capability
becoming the platform.

## 7. Records ENG-0004 owns

ADR-0012 names the schemas. ENG-0004 persists and validates them; it defines no
new record type and invents no field.

| Record | Schema | ENG-0004 role |
|---|---|---|
| Capability definition | `CAPDEF-0000` | stored, validated |
| Capability contract | `CCON-0000` | stored, validated; version negotiation input |
| Capability package | `CPKG-0000` | stored as **governed metadata only** — never loaded, never executed |
| Capability host | `CHOST-0000` | stored, validated; trust subject in `fabric-node` |
| Capability advertisement | `CADV-000000` | stored, validated, expiring; a claim, never a grant |
| Capability instance | `CINST-000000` | the admitted binding; the only routable thing |
| Capability route | `CROUTE-0000` | stored; human-written candidate order |
| Capability selection | `CSEL-000000` | written on every selection and every refusal |

`CAP-0000` platform capability records are **not** fabric capabilities. They are
governance artefacts carrying a maturity claim; nothing routes to them, and the
two never share an identifier space. ENG-0004 must not conflate them.

## 8. Storage

Fabric records reuse the released append-only store already shared by the
occurrence and trust layers — explicit root, refusal of a root inside a git
repository, write-once commit via `os.link`, locked monotonic identifier
allocation, and no update or delete method. This is the existing extraction
point, not a new mechanism, and it already provides exactly the guarantees
ADR-0012's audit section requires.

Two constraints carry over from the Trust Plane and are not relaxed:

- **No default store root.** The root is supplied explicitly, as the trust store
  requires. A defaulted root moves the trust boundary onto whoever typed the
  command.
- **Opening for read never initialises.** ENG-0002 established this for
  `validate-store`; fabric inspection and validation must be read-only on the
  same terms — creating no directory, sequence file, index, temporary file, or
  permission change, whether the target is absent, empty, valid, or malformed.

## 9. Trust verification

ENG-0004 verifies trust **only through released Trust Plane interfaces**. It
does not read trust records directly, reimplement evaluation, cache verdicts, or
add trust semantics of its own.

Admission decisions are Trust Plane decisions in the `capability-package` and
`fabric-node` domains. ENG-0004 consumes their outcome; it never creates,
approves, widens, or restores one, and it never admits on its own authority.

ENG-0004 must not reopen, weaken, or work around any ENG-0001 or ENG-0002
invariant.

## 10. Health input boundary

The fabric's contract with Health is one sentence and one direction:

> **Health may remove a candidate from consideration and may never add one.**

ENG-0004 implements the *boundary*, not the *evaluation*. It accepts an optional
candidate-removal input, applies it after eligibility and before ordered
selection, and records what was removed. It computes no health state, defines no
health semantics, and reads no health record.

The boundary must be **optional**: every ENG-0004 behaviour is specifiable,
implementable, and testable with no Health Runtime present. A healthy instance
that is not trusted is not eligible; an unhealthy instance that is trusted is
trusted and unavailable — a different sentence, and not ENG-0004's to evaluate.

## 11. Validation strategy

Test-first, matching ENG-0001 and ENG-0002: failing behavioural assertions
first, retained as the Red evidence that proves the gap, then the smallest
architecture-compliant change.

**Synthetic fixtures only.** Every behavioural test builds its records in an
isolated temporary store and destroys it. No production store is read or
written, no network, no SSH, no container, no `ai/.env`, and no store inside the
repository. Development and test fixtures are explicitly not production: a
fixture admitting a synthetic node in a temporary store is construction; the
same call against the production trust store is not, and is prohibited until
Gate 2.

Coverage must include, at minimum: each of the eight eligibility conditions
failing in isolation; the default-ineligible rule; empty scope intersection;
expired advertisement and expired admission; absent route; `local-only` refusal
rather than remote degradation; ordered selection determinism across repeated
runs; refusal naming every excluded candidate with its reason; health removing a
candidate; health absent entirely; and read-only inspection mutating nothing.

## 12. Acceptance criteria

ENG-0004 is complete when:

1. Fabric records persist under append-only, write-once semantics, with no
   update or delete path.
2. Admission is governed: default ineligible, no self-admission, no automatic
   registration, no trust on first advertisement.
3. Eligibility evaluates all eight ADR-0012 conditions, and each one failing in
   isolation yields ineligible.
4. Selection is deterministic and reproducible — identical inputs choose the
   identical instance every time.
5. Refusal names every candidate considered and why each was excluded.
6. A selection record is written for every selection **and** every refusal.
7. `locality` is enforced: a `local-only` request refuses rather than leaving
   the host.
8. Trust is verified only through released Trust Plane interfaces; no new trust
   domain exists.
9. Health is an optional removal-only input; all criteria above hold with no
   Health Runtime present.
10. Inspection and validation are read-only and repair nothing.
11. **No capability is loaded, activated, or invoked anywhere in ENG-0004.**
12. All existing suites pass unchanged; ENG-0001 and ENG-0002 invariants intact.
13. No production trust record, counter, or `ai/.env` is read or modified.

## 13. Implementation sequence

Each increment is independently reviewable, with its own test-first plan and
review boundary. Sequence is dependency order.

1. Fabric record models and append-only storage, with read-only validation.
2. Governed host and advertisement admission.
3. Instance admission — the eight-condition eligibility calculation.
4. Route resolution and deterministic ordered selection, including refusal
   records.
5. The optional health removal input boundary.
6. Fabric audit evidence and read-only inspection surface.

Nothing in this sequence loads, activates, or executes a capability. Execution
enters at ENG-0005, under its own accepted specification.

## 14. Deferred and unresolved

- **The non-transactional write risk remains deferred**, exactly as recorded
  under ENG-0001. A crash between immutable writes can leave a partial state,
  and the reverse orphan check does not exist. ENG-0004 inherits this property
  by reusing the append-only store; it neither solves nor redefines it. Any
  ENG-0004 multi-record write must state its ordering so the reachable partial
  states are bounded and known.
- **Scheduler, placement, clustering, and leases remain unassigned.** ENG-0007
  and ENG-0008 are future entries requiring their own accepted specifications.
  No scheduler vocabulary belongs in ENG-0004.
- **Production operation remains closed** behind Gate 2 in full: Fabric
  validated → Health validated → subjects seeded → verdict source ready →
  rollback validated → deployment evidence retained → cutover.

## 15. Related records

- [ADR-0011: The Trust Plane](../../decisions/ADR-0011-trust-plane.md)
- [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
- [ADR-0013: Capability Health Plane](../../decisions/ADR-0013-capability-health-plane.md)
- [Fabric governance boundaries](../../fabric/governance-boundaries.md)
- [Capability Fabric](../../fabric/capability-fabric.md)
- [Post-root runtime sequence](../plans/2026-08-03-post-root-runtime-sequence.md)
- [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)
- [Runtime sequencing correction](../../history/0002-runtime-sequencing-correction.md)
