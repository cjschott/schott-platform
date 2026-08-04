# Fabric Runtime Design (ENG-0004)

> **This document specifies architecture and scope only. It authorises no
> implementation.** No runtime source, scaffolding, executable schema,
> placeholder, or runtime test accompanies it. ENG-0004 implementation begins
> only when this specification is accepted **and** its own test-first plan,
> feature branch, review, and release boundary exist. Gate 1 being satisfied is
> not implementation authorisation.

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

This document settles it, and defines the operational contracts ENG-0004 must
satisfy.

## 2. Entry gate

ENG-0004's entry gate is **Gate 1**, defined in [fabric governance
boundaries](../../fabric/governance-boundaries.md). All three conditions are
satisfied:

| Condition | Evidence |
|---|---|
| Operator Root Authority ceremony complete | `TAUTH-000001`, established out of band by a human |
| ENG-0001 released | `v0.9.7` |
| ENG-0002 released | `v0.9.8` |

**Gate 1 permits construction only.** It does not permit production operation,
and it does not by itself authorise implementation — an accepted specification
and its own reviewed plan are additionally required. Gate 2, the TrustGateway
production cutover gate, is separate, unchanged, and still closed.

## 3. The ENG-0004 / ENG-0005 boundary

**Accepted decision, reviewed and unchanged.** This section records the
architectural decision that closes ADR-0012's documented gap. It refines the
accepted architecture at that boundary and alters ADR-0012, ADR-0013,
`CAP-0000`, Gate 1, and Gate 2 in no respect.

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

## 4. Admission authority model

Trust and admission are **different decisions with different authorities**, and
conflating them is the failure this section exists to prevent. ADR-0012 states
the ordering directly: **"Trust precedes admission. Nothing is admitted that is
not first trusted."**

### Four distinct decisions

| # | Decision | Authority | Record | Establishes |
|---|---|---|---|---|
| 1 | Package trust | Trust Plane, `capability-package` domain | Trust record (Trust Plane) | The package is trusted for a contract |
| 2 | Host trust | Trust Plane, `fabric-node` domain | Trust record (Trust Plane) | The machine is trusted as a fabric node |
| 3 | Subject admission to the fabric | Human operator, Fabric | `capability-host` (`CHOST-0000`) | The host is a fabric participant and **may register advertisements** |
| 4 | Instance admission | Human operator, Fabric | `capability-instance` (`CINST-000000`) | The governed binding of one package to one host for one contract |

Decisions 1 and 2 are **prerequisites**, decided **separately, each with its own
evidence**, by the Trust Plane. As the lifecycle document puts it: *"Trusting
the package trusts no machine. Trusting the machine trusts no package."*

Decisions 3 and 4 are **Fabric admission decisions**. They are separate,
explicitly authorised, and human-approved. ADR-0012's governed-discovery
sequence requires them in order and permits nothing to enter partway:

> subject identified → trust decision exists → **subject admitted** →
> advertisement registered → advertisement queryable → route may reference →
> selection may choose

### The rules this model enforces

- **A trust verdict alone must never create or admit a Fabric instance.**
  Trust makes a subject *eligible to be admitted*. Admission is a separate human
  act with its own record. A system that admitted on trust alone would have made
  the Trust Plane an admission engine, which it is not.
- **Runtime observations, advertisements, and health information never create
  admission authority and never alter authoritative trust state.** An
  advertisement is *"a claim, never a grant"*; it *"confers no trust, creates no
  eligibility, and cannot admit anything — including itself."* Health may only
  remove a candidate from consideration.
- **No self-admission.** *"A host cannot admit itself, widen its own scope,
  trust another host, or accept work the core did not route to it."*
- **No automatic registration, no automatic node admission, no trust on first
  advertisement.**
- **An advertisement from an unadmitted subject is not a pending application; it
  is not a record at all.** It is refused and leaves no queued state.

### Where the admission decision is recorded

The admission decision is carried by the record it creates — subject admission
by `CHOST-0000`, instance admission by `CINST-000000` — each naming **who
approved this binding, on what evidence, and until when**, which is exactly what
ADR-0012's audit requirements demand be immutable and append-only.

This specification introduces **no ninth record type**. ADR-0012 states that it
*"plus the eight schemas are the specification; a future engineer should be able
to build the Fabric from them without inventing behaviour."* A separate
admission-decision schema would be an invention, so the admission decision is
materialised by the governed record whose existence it authorises.

> **Reviewer note.** This is the only point in this specification resolved by
> reading accepted records rather than by an explicit statement. If a distinct
> admission-decision record is intended, that is a ninth schema and a new
> architectural decision, and it must be decided rather than assumed here.

### Evidence dependencies

An instance admission requires, and refuses without: the package trust record
identity and its standing; the host trust record identity and its standing; the
contract and the version the package declares it satisfies; the host's
**verified** resource profile (verified out of band, *"not copied from the
advertisement"*); a fresh advertisement inside its validity window; the
admission scope; and the approving human operator identity with the admission's
expiry.

### Rejection behaviour

Admission **fails closed**. Required trust evidence that is **absent,
malformed, revoked, unsupported, or unverifiable** yields refusal, never a
pending, partial, provisional, or retried admission. A refusal writes an audit
event naming the failed precondition and creates no governed record. *"The
default is ineligible; absence of a record is never permission."*

### Audit linkage

Every admission and every refusal produces Fabric audit evidence referencing the
trust record identities relied upon, the advertisement relied upon, the
approving operator, and the outcome. **Fabric audit records are never
authoritative for Trust Plane decisions**; they reference trust evidence and
never restate, supersede, or substitute for it.

## 5. Component contracts

Eight components, each traced to an accepted requirement. No component performs
capability execution, health evaluation, or remediation.

### C1 — Fabric Record Store

- **Responsibility:** persist Fabric-owned records under append-only,
  write-once semantics.
- **Inputs:** validated record constructions; an explicit store root.
- **Outputs:** durable record paths; allocated identifiers.
- **State ownership:** authoritative for all Fabric-owned records.
- **Trust dependencies:** none directly; it stores what C4 authorises.
- **Failure behaviour:** refuses to overwrite; refuses a root inside a git
  repository; refuses an absent explicit root. Never updates, never deletes.
- **Status:** authoritative.
- **Persistent-write authority:** **yes** — the only component with it.
- **Consumed by later increments:** ENG-0005 may read admitted instances; it may
  never write Fabric-owned records.

### C2 — Record Validator

- **Responsibility:** structural and referential validation of stored records;
  reports problems, repairs none.
- **Inputs:** stored records.
- **Outputs:** deterministic, ordered findings.
- **State ownership:** none.
- **Trust dependencies:** none.
- **Failure behaviour:** a malformed record becomes a finding, never a crash and
  never a repair.
- **Status:** derived.
- **Persistent-write authority:** **none.**
- **Consumed by later increments:** ENG-0005 and ENG-0006 may read findings.

### C3 — Trust Verification Adapter

- **Responsibility:** resolve package and host trust standing **through released
  Trust Plane interfaces only**.
- **Inputs:** trust record identities; an evaluation instant.
- **Outputs:** trust standing and expiry, as the Trust Plane reports them.
- **State ownership:** none. It caches no verdict and stores no trust state.
- **Trust dependencies:** the released Trust Plane read interface.
- **Failure behaviour:** **fails closed.** Unavailable, unreadable, or
  unverifiable trust yields ineligible/refuse — never assumed-trusted, never a
  stale reused verdict.
- **Status:** derived.
- **Persistent-write authority:** **none.** It never writes trust state in
  either direction.
- **Consumed by later increments:** ENG-0005 may consume standing; it may not
  bypass this adapter to reach trust records directly.

### C4 — Admission and Lifecycle Controller

- **Responsibility:** enforce governed subject admission, advertisement
  registration, instance admission, and every legal lifecycle transition.
- **Inputs:** operator-supplied requests with an approving identity; trust
  standing from C3; existing records from C1.
- **Outputs:** new immutable records via C1; refusals with reasons.
- **State ownership:** authoritative for Fabric lifecycle state.
- **Trust dependencies:** C3; refuses when trust is absent, expired, revoked, or
  unverifiable.
- **Failure behaviour:** fails closed; refusal is a first-class recorded
  outcome; illegal transitions are refused and recorded, never coerced.
- **Status:** authoritative.
- **Persistent-write authority:** **yes, via C1 only.**
- **Consumed by later increments:** ENG-0005 reads admitted instances.

### C5 — Eligibility Evaluator

- **Responsibility:** compute ADR-0012's eight-condition eligibility as a pure,
  deterministic, total function at a supplied instant.
- **Inputs:** instance, package, host, advertisement, admission, request
  classification; trust standing from C3; an evaluation instant.
- **Outputs:** eligible/ineligible plus the specific unmet condition(s).
- **State ownership:** none. **Eligibility is derived and never stored as
  authoritative state.**
- **Trust dependencies:** C3.
- **Failure behaviour:** any condition unmet, unreadable, or indeterminate →
  ineligible, with the reason named.
- **Status:** derived.
- **Persistent-write authority:** **none.**
- **Consumed by later increments:** ENG-0005 and ENG-0006 may read eligibility.

### C6 — Selection Engine

- **Responsibility:** resolve a route and select the first eligible candidate in
  human-declared order; record the outcome.
- **Inputs:** request class; route; candidate instances; eligibility from C5; an
  optional health removal set.
- **Outputs:** a Fabric identity or a `capability-selection` record — **never an
  invocation, and never a capability result.**
- **State ownership:** authoritative for selection and refusal records.
- **Trust dependencies:** indirect, via C5.
- **Failure behaviour:** no route → refuse; no eligible candidate → refuse,
  naming every candidate and its exclusion; `local-only` unsatisfiable → refuse
  rather than degrade to a remote instance.
- **Status:** authoritative for the record of the choice.
- **Persistent-write authority:** **yes, via C1** — selection and refusal
  records only.
- **Consumed by later increments:** ENG-0005 consumes the selected identity and
  performs execution.

### C7 — Audit Recorder

- **Responsibility:** write Fabric audit evidence for governed mutations,
  refusals, and selection outcomes.
- **Inputs:** event type, actor, approving authority, causal references,
  outcome, reason category.
- **Outputs:** immutable append-only audit records.
- **State ownership:** authoritative for Fabric audit evidence only.
- **Trust dependencies:** none. **It never writes Trust Plane audit records.**
- **Failure behaviour:** an audit write that cannot be completed is an
  observable failure, never silently skipped.
- **Status:** authoritative for Fabric evidence; **never authoritative for Trust
  Plane decisions.**
- **Persistent-write authority:** **yes, via C1.**
- **Consumed by later increments:** ENG-0005 and ENG-0006 may read.

### C8 — Inspection and Validation Surface

- **Responsibility:** read-only inspection of records and read-only store
  validation.
- **Inputs:** an explicit store root; optional filters.
- **Outputs:** deterministic reports.
- **State ownership:** none.
- **Trust dependencies:** none.
- **Failure behaviour:** an absent, empty, or malformed store is **reported, not
  repaired**. Opening for read never initialises.
- **Status:** derived.
- **Persistent-write authority:** **none — not one byte, under any input.**
- **Consumed by later increments:** any.

## 6. Registration and admission contracts

Common to every contract below: the actor is a **human operator** supplying an
approving identity; there is **no automatic path**; required trust evidence
**fails closed** when absent, malformed, revoked, unsupported, or unverifiable;
a rejection writes audit evidence and **no governed record**; and identifiers
are allocated by the store, never supplied by the requester.

**Determinism, duplicates, replay, idempotency — the common rule.** Fabric
records are immutable and write-once. A repeated request that would create an
already-existing record identity is **refused as a duplicate, not silently
accepted and not overwritten** — the store's write-once commit makes refusing an
overwrite and committing a write the same atomic operation. Replay of a
previously accepted request is therefore **naturally idempotent in effect**: the
first attempt holds, the replay is refused as a duplicate, and both outcomes are
audited. Retrying is an operator decision; nothing retries automatically.

### 6.1 Declare capability, contract, or package

- **Request:** the declaration content. A **contract** additionally declares its
  **effect class**, its **determinism class**, and the **explicit set of prior
  versions it is compatible with**. A **package** declares the **explicit set of
  contract versions it satisfies**.
- **Authority:** human operator. Declaration confers nothing.
- **Trust evidence:** none required — a declaration is a description.
- **Preconditions:** referenced capability and contract identities must exist
  and resolve.
- **Rejection:** unresolved reference; malformed content; duplicate identity;
  absent or unrecognised effect class.
- **Supersession:** a new package version is a **new subject requiring its own
  trust decision**. Supersession is *declared, never inferred from a version
  number or an installation event.* Superseded records remain readable.
- **Durable records:** `CAPDEF-0000`, `CCON-0000`, `CPKG-0000`.
- **Result:** the created record identity.

### 6.2 Admit a subject (host) to the fabric

- **Request:** declared node identity reference, its `fabric-node` trust record
  identity, verified resource profile, location class, data classification
  ceiling, availability intent, approving operator.
- **Authority:** human operator. **No automatic node admission.**
- **Trust evidence:** a `fabric-node` trust record standing at Trusted or
  Restricted, resolved via C3.
- **Preconditions:** the subject was *declared by an operator and verified out
  of band* — *"a hostname is a label, not an identity"*, and *"reinstalling a
  machine makes a new subject"*.
- **Rejection:** absent/expired/revoked/unverifiable host trust; unknown
  identity; self-admission attempt; resource profile copied from an
  advertisement rather than verified.
- **Durable records:** `CHOST-0000`.
- **Result:** the host identity; the subject may now register advertisements.

### 6.3 Register an advertisement

- **Request:** the advertising host identity, held package, satisfied contract
  versions, claimed resources, observation instant, validity window.
- **Authority:** the admitted subject publishes; the core records. **Only an
  admitted subject may register one.**
- **Trust evidence:** the host must be an admitted subject; an advertisement is
  **not** a trust subject.
- **Preconditions:** subject admitted (§6.2); validity window well-formed.
- **Rejection:** unadmitted or unknown subject — *"not a pending application; it
  is not a record at all"*, so nothing is queued; malformed window.
- **Expiry/withdrawal:** advertisements expire by their validity window. Absence
  means the capability is **absent**, not "probably still there". A fresh
  advertisement **never** revives expired admission or expired trust.
- **Durable records:** `CADV-000000`, immutable and expiring.
- **Result:** the advertisement identity.

### 6.4 Admit an instance

- **Request:** package, host, contract version, admission scope, admission
  expiry, referenced advertisement, approving operator.
- **Authority:** human operator, explicitly. **A trust verdict alone must never
  create an instance.**
- **Trust evidence:** package trust and host trust, each resolved separately via
  C3.
- **Preconditions:** all eight ADR-0012 eligibility conditions hold at admission
  time.
- **Rejection:** any of the eight unmet; empty effective scope — *"a valid
  outcome, and it means nothing is eligible"*; self-admission; absent or stale
  advertisement.
- **Supersession/retirement:** an instance is **never reused, renamed, or
  repointed** — *"repointing an instance at a different machine would mean one
  record described two bindings."* Migration destroys the instance and creates a
  new one referencing the same capability and package identities. Retirement
  withdraws by decision; records remain.
- **Durable records:** `CINST-000000`, carrying approver, evidence references,
  and expiry.
- **Result:** the instance identity.

### 6.5 Create or supersede a route

- **Request:** request class (capability, contract version range, data
  classification, locality), the **explicitly ordered human-written** candidate
  list, route version.
- **Authority:** human operator. *"Ordering is written by a human."*
- **Preconditions:** every candidate instance identity resolves.
- **Rejection:** unresolved candidate; ordering derived from any measurement.
- **Supersession:** **cutover is a route change** — a new route version — *"not
  a package event. A package cannot promote itself."* Old and new instances may
  coexist during a declared overlap window.
- **Durable records:** `CROUTE-0000`.
- **Result:** the route version identity.

### 6.6 Withdraw, retire, or supersede

- **Request:** target record identity, reason, approving operator.
- **Authority:** human operator. **Recovery and retirement are decisions, not
  events.**
- **Effect:** instances become ineligible; routes stop listing them; **every
  record stays exactly as written.** Retirement deletes nothing.
- **Durable records:** the superseding or withdrawal record; nothing is edited.
- **Result:** the resulting record identity.

## 7. Lifecycle states and transitions

The six accepted stages, plus the derived status that must never be confused
with them.

**Authoritative lifecycle state** is created only by a recorded decision:
Declared, Trusted, Advertised, Admitted, Superseded, Retired.

**Derived status** — Eligible / Ineligible — is **computed, never stored as
authoritative, and never written back.** *"No stage transition happens
automatically except expiry."* Expiry only ever **removes** eligibility; it
changes no authoritative decision.

Host `availability_intent` (`in-service`, `draining`, `withheld`) is
**operator-set**, and withdrawal is *"by decision rather than by failing"*.

### Normative transition table

Common to every row: **idempotency and replay** — a replayed transition that
would recreate an existing record identity is refused as a duplicate and
audited; the original stands. **Invalid transition** — refused, recorded with
the reason, and no state changes. Nothing is coerced into a legal state.

| # | Source | Trigger | Actor / authority | Preconditions | Result | Durable records | Supersession / expiry | Audit |
|---|---|---|---|---|---|---|---|---|
| 1 | *(none)* | Declaration written | Human operator | References resolve | **Declared** | `CAPDEF`/`CCON`/`CPKG` | Superseded by declaration only | Creation event |
| 2 | Declared | Package trust decision | **Trust Plane**, `capability-package` | Own evidence | **Trusted** (package) | Trust record *(Trust Plane)* | Trust expiry clock | Trust Plane audit; Fabric references it |
| 3 | Declared | Host trust decision | **Trust Plane**, `fabric-node` | Own evidence, decided separately | **Trusted** (host) | Trust record *(Trust Plane)* | Trust expiry clock | Trust Plane audit; Fabric references it |
| 4 | Trusted (host) | Subject admission | **Human operator**, Fabric | Host trust standing; identity verified out of band | **Admitted subject** | `CHOST` | Withdrawn by decision | Admission event |
| 5 | Admitted subject | Advertisement registered | Admitted subject publishes; core records | Subject admitted; window well-formed | **Advertised** | `CADV` | **Advertisement validity clock** | Registration event |
| 6 | Advertised + both Trusted | Instance admission | **Human operator**, Fabric | All eight conditions hold | **Admitted instance** | `CINST` | **Admission expiry clock** | Admission event with evidence references |
| 7 | Admitted instance | Route created / versioned | Human operator | Candidates resolve | Route version active | `CROUTE` | New route version supersedes | Route event |
| 8 | Admitted instance | Declared supersession | Human operator | Overlap window declared | **Superseded** | New `CINST` + new `CROUTE` version | Old remains readable | Supersession event |
| 9 | Admitted instance | Withdrawal / retirement | Human operator | — | **Retired** | Withdrawal record | Records remain; nothing deleted | Retirement event |
| 10 | Any trusted state | Trust revoked or quarantined | Trust Plane | — | Trust standing changes | Trust record *(Trust Plane)* | Instance becomes **ineligible** (derived) | Trust Plane audit |
| 11 | Advertised | Advertisement validity lapses | **Automatic (expiry only)** | Window elapsed | Claim stale → **ineligible** (derived) | none — no record is written | Never auto-renews | Observable on evaluation |
| 12 | Admitted instance | Admission expiry lapses | **Automatic (expiry only)** | Expiry elapsed | Binding lapsed → **ineligible** (derived) | none | A fresh advertisement **never** revives it | Observable on evaluation |
| 13 | Admitted instance | Host set `draining`/`withheld` | Human operator | — | **Ineligible** (derived); authoritative admission unchanged | `CHOST` supersession | By decision, not failure | Intent-change event |
| 14 | Admitted instance | Host disappears | *(no actor)* | — | **Ineligible** (derived) **only**; **no authoritative state changes** | **none** | Absence means absent, not continuity | Recorded at selection as an exclusion |
| 15 | Admitted instance | Health reports outside envelope | Health (ENG-0006), optional | — | **Candidate removed** for this selection only | none | Removal only; never adds, never reorders | Recorded as an exclusion reason |
| 16 | Retired / expired | Return of a host | **Human decision required** | New decision, new evidence | Remains **untrusted** until decided | New decision records | *"Recovery is a decision, not an event"* | Recorded when decided |
| 17 | Unknown identity | Any request referencing it | — | — | **Refused** — `Unknown` fails closed | none | — | Refusal event |

Rows 11–15 are the ones that must never be mistaken for authoritative change:
**eligibility, availability, disappearance, and health observations never
silently alter authoritative trust or admission state.**

## 8. Behavioural interfaces

Operations are specified by behaviour, not by language, CLI spelling,
transport, or code structure. Common to all: **authorisation is an explicit
approving operator identity for every write**; **no default store root**; output
is deterministic; and error categories are `refused` (governed refusal),
`invalid` (malformed input), `not-found` (unresolved reference), `conflict`
(duplicate identity), and `unavailable` (dependency unreachable — fails closed).

| # | Operation | Purpose | Inputs | Required output fields | Auth | Preconditions | Success | Errors | R/W | Idempotency / replay | Audit |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Declare capability | Record an abstract ability | declaration content | identity, kind | operator | references resolve | record written | invalid, conflict | **W** | duplicate refused | creation |
| 2 | Declare contract | Record a versioned interface | contract content, version | identity, version | operator | capability resolves | record written | invalid, not-found, conflict | **W** | duplicate refused | creation |
| 3 | Declare package | Record a package claiming contracts | package content, satisfied versions | identity, claimed versions | operator | contracts resolve | record written | invalid, not-found, conflict | **W** | duplicate refused | creation |
| 4 | Admit subject | Make a host a fabric participant | host fields, trust record id, approver | host identity, approver, trust reference | operator | host trust standing valid | record written | refused, unavailable, conflict | **W** | duplicate refused | admission |
| 5 | Register advertisement | Record a host's claim | host id, package, versions, resources, window | advertisement identity, window | admitted subject | subject admitted | record written | refused, invalid, not-found | **W** | duplicate refused | registration |
| 6 | Admit instance | Create the governed binding | package, host, contract version, scope, expiry, advertisement, approver | instance identity, approver, evidence refs, expiry | operator | all eight conditions | record written | refused, unavailable, conflict | **W** | duplicate refused | admission with evidence |
| 7 | Create/supersede route | Declare ordered candidates | request class, ordered candidates, version | route identity, version, ordered list | operator | candidates resolve | record written | invalid, not-found, conflict | **W** | duplicate refused | route event |
| 8 | Withdraw / retire / supersede | End eligibility by decision | target id, reason, approver | resulting identity, reason | operator | target resolves | record written; **nothing edited** | not-found, invalid | **W** | duplicate refused | retirement |
| 9 | Compute eligibility | Explain eligibility at an instant | instance id, request classification, instant | eligible flag, per-condition results, unmet reasons | read | store readable | deterministic verdict | unavailable → ineligible | **R** | pure; repeatable | none required |
| 10 | Select | Choose deterministically | request class, instant, optional health removals | route + version, every candidate, per-candidate exclusion reason, chosen identity **or** refusal reason | read + selection write | route resolves | first eligible in declared order | refused (no route / none eligible / `local-only`) | **R + selection record** | replay writes a new selection record; the choice is identical for identical inputs | **selection or refusal record, always** |
| 11 | Inspect | Read records | store root, filters | matching records, deterministic order | read | — | report | not-found, invalid | **R only** | pure | none |
| 12 | Validate | Report structural problems | store root | findings in deterministic order, counts | read | — | report; **repairs nothing** | invalid | **R only** | repeated validation returns identical output | none |

**Operations 11 and 12 are genuinely read-only.** Opening an absent store must
not initialise, repair, backfill, or mutate it — no store root, record
directory, sequence file, index, temporary file, permission, or ownership
change, whether the target is absent, empty, valid, or malformed. This is the
ENG-0002 contract, applied to the Fabric store.

**Operation 10 returns a Fabric identity or a selection/refusal record and never
invokes a capability.** Invocation is ENG-0005.

### Selection constraints

Three constraints bind eligibility and selection. All three are settled by
ADR-0012; none is a new decision, and none may be relaxed per-route or by
configuration.

#### Effect class — `side-effecting` is representable but unroutable

Every contract declares an **effect class**, which is the axis governance cares
about and is **separate from determinism**.

| Class | Changes | Routable |
|---|---|---|
| `read-only` | nothing | Yes, subject to trust and contract |
| `computational` | nothing outside the request | Yes, subject to trust and contract |
| `content-generating` | nothing outside the request | Yes, subject to trust and contract |
| `side-effecting` | state outside the request | **No — unroutable** |

ENG-0004 must enforce, at selection time: **no route may select a
`side-effecting` contract, no selection may choose one, and no route may
override the prohibition.** *"A restriction that can be lifted per-route is one
that gets lifted during an incident."* A route naming a `side-effecting`
candidate is refused, and the refusal is recorded like any other.

The class is **representable** so a future actuating capability can be described
without being permitted. Enabling it is out of scope for ENG-0004 and requires
all six conditions in §15.

#### Version negotiation — set intersection, no cleverness

Negotiation happens **against contracts, never packages**.

- A request declares a contract and an **explicit set of accepted versions**.
- A package declares the **explicit set of contract versions it satisfies**.
- The eligible set is the **intersection**. **Empty → refuse.**

**Compatibility is declared, never inferred.** A contract names its compatible
prior versions in a reviewed field. The platform **never reads meaning into a
version number** — semantic-versioning arithmetic is a convention followed
imperfectly, and treating it as a guarantee lets a string comparison make an
upgrade decision.

**No automatic upgrade, no automatic downgrade, no nearest match, no
best-effort.** A request that cannot be satisfied **exactly** is refused.

#### The Health input boundary

The fabric's contract with Health is one sentence and one direction:

> **Health may remove a candidate from consideration and may never add one.**

ENG-0004 implements the **boundary**, not the **evaluation**. It accepts an
optional candidate-removal input, applies it **after** eligibility and **before**
ordered selection, records what was removed, and computes no health state,
defines no health semantics, and reads no health record.

The boundary is **optional**: every ENG-0004 behaviour is specifiable,
implementable, and testable with **no Health Runtime present**.

**Unknown stays unknown.** Until Health Runtime exists, health is *declared or
unknown*, and **missing health data is never treated as healthy** — *"treating
missing data as healthy is how an unmonitored node becomes the preferred one."*
Absent health input removes no candidate; it never adds, promotes, or reorders
one either.

Health **cannot** grant trust, override quarantine, broaden scope, or admit a
node. A healthy instance that is not trusted is not eligible; an unhealthy
instance that is trusted is trusted and unavailable — a different sentence, and
not ENG-0004's to evaluate.

Symmetrically, **selection outcomes are never trust evidence.** The Trust Plane
does not use routing outcomes as evidence of trustworthiness: *"a capability
that has been selected and has returned correct answers for six months has
earned nothing."*

## 9. Failure and recovery matrix

`Reject` = refuse the request. `Report` = surface as a finding or exclusion.
`Retry` = automatic retry (**never** — retrying is always an operator decision).
`Read-only` = the condition never provokes a write. `Operator` = explicit
operator action required to progress.

| # | Condition | Reject | Report | Retry | Read-only | Operator | Behaviour |
|---|---|---|---|---|---|---|---|
| 1 | Absent Fabric store | — | ✔ | ✖ | ✔ | ✔ | Reported as absent. **Not created, not initialised.** Writes refuse |
| 2 | Empty Fabric store | — | ✔ | ✖ | ✔ | — | Valid and reported as empty; distinguishable from absent |
| 3 | Malformed record | — | ✔ | ✖ | ✔ | ✔ | Deterministic finding; never a crash; **never repaired** |
| 4 | Unknown/unsupported schema or record version | ✔ | ✔ | ✖ | ✔ | ✔ | **Fails closed.** Never guessed, never migrated implicitly |
| 5 | Missing reference | ✔ | ✔ | ✖ | ✔ | ✔ | `not-found`; nothing created |
| 6 | Duplicate request | ✔ | ✔ | ✖ | — | ✔ | `conflict`; original stands; never overwritten |
| 7 | Replay | ✔ | ✔ | ✖ | — | — | Refused as duplicate; effect idempotent; both audited |
| 8 | Interrupted write | — | ✔ | ✖ | ✔ | ✔ | Temp residue is **observable debris**, reported as a finding. **Not cleaned automatically** |
| 9 | Concurrent writers | ✔ | ✔ | ✖ | — | ✔ | Identifier allocation is lock-serialised; the loser sees `conflict` |
| 10 | Trust Plane unavailable | ✔ | ✔ | ✖ | ✔ | ✔ | **Fails closed.** No cached or assumed verdict |
| 11 | Invalid / expired / revoked authority | ✔ | ✔ | ✖ | ✔ | ✔ | Refused; instance becomes ineligible (derived only) |
| 12 | Stale / missing / corrupt derived state | — | ✔ | ✖ | ✔ | — | Derived state is **recomputed, never trusted and never repaired**; it is authoritative for nothing |
| 13 | Advertisement expired | — | ✔ | ✖ | ✔ | ✔ | Ineligible (derived). **A fresh advertisement never revives admission or trust** |
| 14 | Host disappearance | — | ✔ | ✖ | ✔ | ✔ | Ineligible (derived) **only**. No authoritative change; recovery is a decision |
| 15 | Permission / ownership mismatch | ✔ | ✔ | ✖ | ✔ | ✔ | Refused and reported. **Never silently corrected** |
| 16 | Symlink or path-boundary violation | ✔ | ✔ | ✖ | ✔ | ✔ | Refused after full resolution; never followed outside the root |
| 17 | Store root inside a git repository | ✔ | ✔ | ✖ | ✔ | ✔ | Refused, per the released store contract |
| 18 | No route for a request class | ✔ | ✔ | ✖ | — | ✔ | Refuse; **selection record written** |
| 19 | No eligible candidate | ✔ | ✔ | ✖ | — | ✔ | Refuse naming **every** candidate and its exclusion; refusal record written |
| 20 | `local-only` unsatisfiable | ✔ | ✔ | ✖ | — | ✔ | **Refuse rather than degrade** to a remote instance |
| 21 | Explicit recovery after failure | — | ✔ | ✖ | ✔ | ✔ | **A decision, not an event.** New records by new decisions |
| 22 | `side-effecting` contract routed or selected | ✔ | ✔ | ✖ | — | ✔ | **Unroutable.** Refused; **no route may override**; refusal recorded |
| 23 | Empty contract version intersection | ✔ | ✔ | ✖ | — | ✔ | Refuse. **No upgrade, downgrade, nearest match, or best-effort** |
| 24 | Health input absent or unknown | — | ✔ | ✖ | ✔ | — | **Unknown stays unknown**; removes nothing, adds nothing, never read as healthy |

**Recovery performs no implicit repair, no trust backfill, no synthetic evidence
generation, and no silent authoritative-state change.** Every one of the
prohibited remediations in the accepted architecture stands: no restart, no
redeploy, no requeue, no re-admission, no automatic drain or quarantine, no
acceptance of a fresh advertisement as a recovery signal, no trust change in
either direction, and no retry that silently changes a selection.

### The interrupted-write boundary, preserved rather than solved

The append-only store has **no transaction**. Multi-record writes are not
atomic, and nothing deletes or rewrites, so an interruption leaves a permanent
partial state. This is the risk recorded under ENG-0001, inherited here and
**neither solved nor redefined**.

What ENG-0004 must do instead: **declare its write ordering** so the reachable
partial states are bounded and known; make residue **observable** — a temp file
is debris reported as a finding, never mistaken for a record and never removed
automatically; and require **explicit operator action** to resolve. Because
records are immutable and never edited, a partial state is always additive and
never a corrupted record.

## 10. Persistence model

**Fabric-owned root and namespace separation.** The Fabric store has its **own
explicit root**, separate from the production Trust Plane store. **No Fabric
mutable data is written into Trust Plane directories**, and the Fabric never
writes any Trust Plane record.

**Reuse of the released store, only where its accepted contract applies.** The
Fabric reuses the shared append-only store: explicit root, refusal of a root
inside a git repository, write-once commit via `os.link` so committing a write
and refusing an overwrite are the same atomic operation, lock-serialised
monotonic identifier allocation, and **no update and no delete method**. Three
constraints carry over unrelaxed:

- **No default store root** — supplied explicitly, always.
- **Opening for read never initialises** — the ENG-0002 contract.
- **Inspection never mutates.**

**Authoritative records by type:** `CAPDEF-0000`, `CCON-0000`, `CPKG-0000`,
`CHOST-0000`, `CADV-000000`, `CINST-000000`, `CROUTE-0000`, `CSEL-000000`, plus
Fabric audit events. **No ninth record type is introduced.** No field is
invented to make a schema look complete; every field this specification relies
on is named by ADR-0012, the node model, or the lifecycle document.

**Derived indexes and caches.** Any index is **derived, rebuildable, and
authoritative for nothing.** Eligibility is never persisted as authoritative
state. A missing, stale, or corrupt index is recomputed or reported — never
repaired in place, and never treated as evidence.

**Identifier allocation and deterministic identity.** Identifiers are allocated
by the store under an exclusive lock, are monotonic, skip any name already
occupied, and are **never supplied by the requester**. Record identity is the
allocated identifier; a request that would recreate an existing identity is
refused as a duplicate.

**Record and schema version handling.** Every record carries its schema
identity. An unknown or unsupported version **fails closed** — never guessed,
never implicitly migrated.

**Immutable append and supersession linkage.** Nothing is edited. Supersession
is a **new record naming what it supersedes**; the superseded record remains
readable. Instances are never reused, renamed, or repointed.

**Atomicity boundaries, ordering, concurrency.** A single record write is
atomic. **A multi-record operation is not.** Each such operation must declare
its ordering so that any partial state is bounded and known; the accepted
ordering principle is that a record is never written before the record it
depends on exists. Concurrent writers are serialised at identifier allocation;
the loser of a race sees a duplicate conflict, never a silent overwrite.

**Permissions, ownership, symlinks.** Directories and records are created with
restrictive modes and preserved ownership; a mismatch is **reported, never
silently corrected**. Paths are resolved fully and checked for containment
within the root; a symlink or traversal escaping the root is **refused**.

**Absent and empty stores.** Both are valid inputs to inspection and validation
and are **reported distinctly**: absent is reported as absent — **not created**;
empty is reported as empty. Neither is repaired, and neither causes a write.

**Corruption and recovery.** A corrupt or unreadable record is a deterministic
finding. Recovery is by explicit operator decision producing new records — never
by implicit repair.

## 11. Audit contract

Fabric audit events are immutable, append-only, and superseded rather than
edited. The minimum event contract:

| Field | Requirement |
|---|---|
| Event identity | Store-allocated, deterministic, unique |
| Event type and version | Explicit; unknown version fails closed |
| Actor | The requesting identity |
| Approving authority | The approving human operator, for every governed mutation |
| Request / replay identity | Correlates a request with its replay and its refusal |
| Causal record references | Every record the decision relied on or produced |
| Prior and resulting state | Where a transition changes authoritative state |
| Trust evidence references | The trust record identities relied upon — **referenced, never restated** |
| Outcome | `success`, `refusal`, `rejection`, or `no-candidate` |
| Reason category | Named, from a controlled vocabulary |
| Selection / refusal linkage | Selection events reference the route, version, and selection record |
| Ordering | Append order preserved; events are readable in deterministic order |
| Timestamp | **Caller-supplied and timezone-aware.** Nothing in this layer reads a clock — the released convention, and this path introduces no exception |

**Evidence is required for:** every governed mutation (declaration, subject
admission, advertisement registration, instance admission, route change,
withdrawal/retirement/supersession); every **rejection and refusal**; every
**invalid transition attempt**; every **validation failure surfaced through a
governed operation**; and every **selection outcome, including refusals and
no-candidate results**.

Two questions must be answerable **from records alone**: *"why did this run
there?"* and *"what was this machine allowed to do in March?"* — and, because
refusal is first-class, *"why did nothing run?"*

**Boundaries.** Fabric audit records are **never authoritative for Trust Plane
decisions**; they reference trust evidence and never restate or supersede it.
The Fabric writes **no Trust Plane audit record** and generates **no synthetic
production evidence**.

## 12. Security boundary

- **Least-privilege runtime identity.** No elevated privilege; no privileged
  operation; no host mutation.
- **Filesystem permissions and ownership.** Restrictive directory and file modes
  as the released store applies; ownership preserved; a mismatch is reported and
  never silently corrected.
- **Trust boundary.** Trust standing is obtained **only** through released Trust
  Plane interfaces. The Fabric never writes trust state and never caches a
  verdict.
- **Input validation.** Every request is validated by reconstruction — not by
  field-name presence — so a record whose keys are right and whose values are
  nonsense cannot satisfy a rule.
- **Identifier and metadata validation.** Identifiers must match their declared
  patterns before use in any path. Untrusted metadata — advertisement contents
  above all — is **data, never instruction**, and never widens scope, alters
  trust, or influences ordering.
- **Command-injection resistance.** The Fabric runtime **executes nothing**: no
  subprocess, no shell, no `eval`, no dynamic import of package contents. A
  package record is metadata; **its contents are never loaded or executed** by
  ENG-0004.
- **Path-traversal and root-boundary enforcement.** Paths are resolved fully and
  verified contained within the explicit root before any access.
- **Symlink handling.** Symlinks escaping the root are refused, matching the
  released approved-directory containment rule.
- **Secrets and credentials.** **No credential material in any fabric record** —
  an accepted prohibition. No secret is read, stored, logged, or brokered;
  secret brokering is ENG-0005.
- **Log and error redaction.** Errors name the refusal and the record identity,
  never record values or secret material. No full request or response bodies.
- **Resource limits and denial of service.** Inputs are bounded before parsing;
  identifier sequences refuse exhaustion rather than rolling over; validation is
  linear in stored records and holds no unbounded state. An unadmitted subject's
  advertisement is **refused without creating state**, so unsolicited traffic
  cannot accumulate queued records.
- **Fail-closed conditions.** Unknown identity, unavailable Trust Plane, unknown
  schema version, unverifiable evidence, indeterminate eligibility, and absent
  records **all fail closed**. *"Absence of a record is never permission."*
- **Safe reporting.** Inspection and validation may **report** any of the above
  without mutating anything — the one behaviour explicitly permitted to observe
  a problem and leave it in place.

## 13. Acceptance criteria

**Validation strategy.** Test-first, matching ENG-0001 and ENG-0002: failing
behavioural assertions first, retained as the Red evidence that proves the gap,
then the smallest architecture-compliant change. **Synthetic fixtures only** —
every behavioural test builds its records in an isolated temporary store and
destroys it. No production store is read or written, no network, no SSH, no
container, no `ai/.env`, and no store inside the repository. Development and
test fixtures are explicitly not production: a fixture admitting a synthetic
subject in a temporary store is construction; the same call against the
production trust store is not, and remains prohibited until Gate 2.

Each criterion states setup, observable operation, and required outcome. **No
result is claimed here; nothing has been implemented or executed.**

1. **Isolated initialisation.** Given a fresh temporary root, when a write
   operation initialises the store, then only Fabric directories are created,
   under restrictive modes, inside that root and nowhere else.
2. **No default root.** Given no store root supplied, when any operation runs,
   then it refuses as an invocation error.
3. **Deterministic registration identity.** Given a valid declaration, when it
   is recorded twice with identical content, then two distinct allocated
   identifiers result and neither overwrites the other.
4. **Duplicate refusal.** Given an existing record identity, when a write would
   recreate it, then the write is refused as a conflict and the original is
   byte-unchanged.
5. **Replay idempotency.** Given an accepted request, when it is replayed, then
   the replay is refused as a duplicate, the original stands, and both outcomes
   are audited.
6. **Authorisation required.** Given a governed mutation with no approving
   operator identity, when it is attempted, then it is refused.
7. **Trust validation.** Given a package or host whose trust is absent,
   expired, revoked, malformed, or unverifiable, when admission is attempted,
   then it is refused and no governed record is created.
8. **Trust Plane unavailable fails closed.** Given the Trust Plane read
   interface unavailable, when admission or eligibility runs, then the result is
   refuse/ineligible — never assumed-trusted and never a cached verdict.
9. **Separate Fabric admission approval.** Given a package and host both fully
   trusted, when no Fabric instance admission has been approved, then **no
   instance exists and nothing is eligible**.
10. **Trust alone never admits.** Given only trust records, when eligibility is
    computed, then the absent admission is named as the unmet condition.
11. **Subject admission precedes advertisement.** Given an unadmitted subject,
    when it registers an advertisement, then the registration is refused and
    **no pending or queued record is created**.
12. **No self-admission.** Given a request whose approving identity is the
    subject itself, when admission is attempted, then it is refused.
13. **Eight-condition eligibility.** Given an otherwise eligible instance, when
    each of the eight conditions is made to fail **in isolation**, then each
    yields ineligible and names that specific condition.
14. **Empty scope intersection.** Given non-overlapping package, host, and
    admission scopes, when eligibility is computed, then the instance is
    ineligible with the empty intersection named.
15. **Legal transitions.** Given each legal transition in §7, when performed
    with its required actor and preconditions, then the specified records are
    written and audited.
16. **Illegal transitions.** Given each illegal transition, when attempted, then
    it is refused, recorded, and **no state changes**.
17. **Expiry removes eligibility only.** Given trust, advertisement, or
    admission expiry, when eligibility is computed, then the instance is
    ineligible and **no authoritative record changed**.
18. **No revival by advertisement.** Given an expired admission or expired
    trust, when a fresh advertisement is registered, then the instance remains
    ineligible.
19. **Supersession.** Given a declared supersession with an overlap window, when
    both instances are inspected, then both remain readable and the cutover is a
    new route version.
20. **Deterministic selection.** Given identical inputs, when selection runs
    repeatedly, then the identical instance is chosen every time.
21. **Declared order honoured.** Given multiple eligible candidates, when
    selection runs, then the **first in human-declared route order** is chosen,
    with no reordering by any measurement.
22. **No eligible candidate.** Given every candidate ineligible, when selection
    runs, then it refuses, names **every** candidate with its exclusion reason,
    and writes a refusal record.
23. **`local-only` refuses.** Given a `local-only` request with no eligible
    local instance, when selection runs, then it refuses and **does not** select
    a remote instance.
24. **Health removes only.** Given a health removal set, when selection runs,
    then removed candidates are excluded and health **never adds or reorders**.
25. **Operates without Health Runtime.** Given no Health Runtime present, when
    every operation in §8 runs, then all behave correctly and no operation
    requires health.
26. **Selection never invokes.** Given a successful selection, when the result
    is inspected, then it contains a Fabric identity or selection record and
    **no capability was loaded, activated, or invoked**.
27. **Package contents never loaded.** Given a package record, when any ENG-0004
    operation runs, then package contents are never read, imported, or executed.
28. **Read-only inspection.** Given a valid store, when inspection runs twice,
    then filesystem paths, modes, sizes, timestamps, and digests are identical
    before and after.
29. **Read-only validation, absent store.** Given an absent store root, when
    validation runs, then the target is **not created** and the parent is
    byte-unchanged.
30. **Empty store.** Given an empty store, when validation runs, then it reports
    empty, distinguishably from absent, and creates no directory.
31. **Malformed record.** Given a malformed record, when validation runs, then a
    deterministic finding is reported, nothing crashes, and nothing is repaired.
32. **Unsupported version.** Given an unknown schema version, when it is read,
    then the operation fails closed and never guesses or migrates.
33. **Interrupted write visibility.** Given temp residue from an interrupted
    write, when validation runs, then it is reported as debris and **not
    removed**.
34. **Concurrent writers.** Given simultaneous allocation, when both proceed,
    then identifiers are unique and monotonic and the loser sees a conflict.
35. **Audit contents.** Given each governed mutation and each refusal, when
    audit is inspected, then every required §11 field is present, including
    approving authority and causal references.
36. **Causal linkage.** Given a selection or refusal, when audit is inspected,
    then route, route version, candidates, exclusions, and outcome are
    reconstructable **from records alone**.
37. **Permissions and ownership.** Given a store with a mode or ownership
    mismatch, when any operation runs, then it is reported and **never silently
    corrected**.
38. **Path traversal rejected.** Given an identifier or path escaping the root,
    when used, then it is refused after full resolution.
39. **Symlink rejected.** Given a symlink escaping the root, when accessed, then
    it is refused.
40. **Derived staleness.** Given a stale or corrupt derived index, when
    eligibility or selection runs, then results are recomputed from
    authoritative records and the index is authoritative for nothing.
41. **Explicit recovery.** Given a failed or partial state, when recovery is
    performed, then it proceeds only by a new operator decision producing new
    records.
42. **No implicit repair.** Given any failure condition in §9, when any
    operation runs, then no record is created, altered, cleaned, or backfilled
    implicitly.
43. **No production mutation.** Given the full suite, when it completes, then
    the production trust store, its counters, and `ai/.env` are byte-identical,
    and every fixture was an isolated temporary store.
44. **No Trust Plane regression.** Given the full suite, when it completes, then
    all ENG-0001 and ENG-0002 assertions pass unchanged.
45. **Deterministic repeated validation.** Given any store state, when
    validation runs repeatedly, then output is identical and the filesystem is
    unchanged.
46. **Separation from Capability and Health Runtime.** Given the delivered
    increment, when it is inspected, then it contains no execution adapter,
    worker, dispatcher, provider connector, health evaluator, or remediation
    path.
47. **Unresolved reference.** Given a request naming a capability, contract,
    package, host, advertisement, or candidate instance that does not resolve,
    when it is submitted, then it is refused as not-found and no record is
    created.
48. **No route.** Given a request class with no resolvable route, when selection
    runs, then it refuses, and the refusal is recorded — distinguishably from
    the no-eligible-candidate outcome.
49. **Host disappearance changes nothing authoritative.** Given an admitted
    instance whose host has disappeared, when eligibility and selection run,
    then the instance is excluded as a derived outcome only, **no authoritative
    record changes**, and re-eligibility requires a new decision.
50. **Store root inside a repository refused.** Given a store root inside a git
    repository, when any operation runs, then it is refused and nothing is
    created.
51. **`side-effecting` is unroutable.** Given a contract declaring
    `side-effecting`, when a route names it or selection considers it, then it
    is refused and no selection chooses it.
52. **No per-route override of unroutability.** Given a route configured to
    permit a `side-effecting` candidate, when selection runs, then the
    prohibition still holds and the route cannot lift it.
53. **Effect class required.** Given a contract with an absent or unrecognised
    effect class, when it is declared, then the declaration is refused.
54. **Version negotiation is exact intersection.** Given a request's accepted
    version set and a package's satisfied version set, when eligibility is
    computed, then only the intersection is eligible and an empty intersection
    refuses.
55. **No version cleverness.** Given a request that cannot be satisfied exactly,
    when selection runs, then it refuses — with no automatic upgrade,
    downgrade, nearest match, or best-effort substitution, and no meaning read
    from any version number.
56. **Declared compatibility only.** Given a contract compatible with prior
    versions, when negotiation runs, then only the reviewed declared
    compatibility field is consulted.
57. **Unknown health is never healthy.** Given absent or unknown health input,
    when selection runs, then no candidate is removed **and** none is added,
    promoted, or reordered, and missing data is never treated as healthy.
58. **Health cannot grant, override, broaden, or admit.** Given health input,
    when it is applied, then it cannot grant trust, override quarantine, broaden
    scope, or admit a node.
59. **Selection outcomes are never trust evidence.** Given a history of
    successful selections, when trust is evaluated, then nothing about that
    history alters trust standing.

## 14. Implementation planning outline

**Non-authorising and high level.** This outline proposes work packages; it
does not authorise, sequence-commit, or begin any of them. Each package requires
its own accepted test-first plan and review boundary. No release version is
proposed.

| # | Work package | Deliverable | Dependencies | Review boundary | Required Red evidence | Required Green evidence |
|---|---|---|---|---|---|---|
| 1 | Contract and schema tests | Behavioural assertions for record shape, identity patterns, version handling | — | Independent | Assertions fail with no models present | All pass; no other suite changes |
| 2 | Isolated storage primitives | Fabric store over the released append-only store | 1 | Independent | Write/immutability/no-default-root assertions fail | All pass; ENG-0002 read-only contract holds |
| 3 | Registration and admission validation | Governed subject, advertisement, instance admission; fail-closed trust | 2 | Independent | Admission-without-trust and self-admission assertions fail | All pass; refusals audited |
| 4 | Lifecycle transition enforcement | Legal transitions; illegal refused; expiry derived-only | 3 | Independent | Illegal-transition and expiry assertions fail | All pass; no authoritative change on expiry |
| 5 | Eligibility and selection | Eight-condition eligibility; deterministic ordered selection; refusal records | 4 | Independent | Per-condition and determinism assertions fail | All pass; refusal records written |
| 6 | Read-only inspection and validation | Inspection and validation surfaces | 2 | Independent | Absent/empty/malformed non-mutation assertions fail | All pass; digests unchanged |
| 7 | Audit generation | Event contract, causal linkage | 3–5 | Independent | Missing-field and linkage assertions fail | All pass; questions answerable from records |
| 8 | Interface integration | The §8 operations wired end to end | 2–7 | Independent | Operation-level assertions fail | All pass; deterministic output |
| 9 | Failure injection and concurrency | Interrupted writes, concurrent allocation, unavailable Trust Plane, permission/symlink violations | 8 | Independent | Failure-matrix assertions fail | All pass; no implicit repair |
| 10 | Full regression validation | Whole-repository validation | 9 | Independent | — | All suites pass; `run-validation.sh` full; production byte-identical |

## 15. Deferred and unresolved

- **The non-transactional write risk remains deferred**, exactly as recorded
  under ENG-0001, and is **restated rather than solved** (§9). ENG-0004 inherits
  it by reusing the append-only store, bounds it by declared write ordering,
  makes residue observable, and requires explicit operator recovery.
- **The admission-decision record location** (§4) is resolved by reading
  accepted records — the decision is carried by the record it creates, because a
  ninth schema would be an invention. If a distinct admission-decision record is
  intended, that is a new architectural decision.
- **`side-effecting` enablement is out of scope and stays out.** Making an
  actuating capability routable requires **all six** of ADR-0012's conditions: a
  new ADR governing actuation on its own terms, an explicit approval model,
  per-effect effect authorisation, remediation boundaries, audit requirements
  for effects that reached the world, and human approval semantics. ENG-0004
  represents the class and refuses to route it; it enables nothing.
- **Scheduler, placement, clustering, and leases remain unassigned** to ENG-0007
  and ENG-0008, each requiring its own accepted specification. No scheduler
  vocabulary belongs in ENG-0004.
- **Distribution across instances** is undefined by ADR-0012 and stays that way:
  it must arrive as a declared deterministic route rule, never a load
  measurement, and *"no such rule is defined in this release."*
- **Production operation remains closed** behind Gate 2 in full.

## 16. Related records

- [ADR-0011: The Trust Plane](../../decisions/ADR-0011-trust-plane.md)
- [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
- [ADR-0013: Capability Health Plane](../../decisions/ADR-0013-capability-health-plane.md)
- [Fabric governance boundaries](../../fabric/governance-boundaries.md)
- [Capability Fabric](../../fabric/capability-fabric.md)
- [Capability lifecycle](../../fabric/capability-lifecycle.md)
- [Capability identity](../../fabric/capability-identity.md)
- [Capability routing](../../fabric/capability-routing.md)
- [Failure behaviour](../../fabric/failure-behaviour.md)
- [Node model](../../fabric/node-model.md)
- [Post-root runtime sequence](../plans/2026-08-03-post-root-runtime-sequence.md)
- [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)
- [Runtime sequencing correction](../../history/0002-runtime-sequencing-correction.md)
