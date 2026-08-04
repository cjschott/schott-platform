# ADR-0012: The Distributed Capability Fabric

- **Status:** Accepted
- **Date:** 2026-08-03
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved.

> **This ADR defines architecture only. There is no runtime implementation in
> this release** — no fabric engine, no registry service, no scheduler, no
> placement, no networking, no execution, no remediation, no Docker change, no
> SSH. This document plus the eight schemas are the specification; a future
> engineer should be able to build the Fabric from them without inventing
> behaviour. Where something is undecided, this ADR says so explicitly rather
> than leaving a gap for whoever implements it first.

> **Specification may proceed before Operator Root deployment acceptance.**
> This ADR is the same move ADR-0011 made: the architecture is written first,
> deliberately, so that the thing being governed does not get to shape its own
> governance. See [Governance boundaries](../fabric/governance-boundaries.md)
> for the current gate requirements.

> **Superseded as of 2026-08-04 — original entry condition.** As accepted, this
> ADR stated that runtime implementation, node admission, capability
> registration, routing, selection, and execution remained blocked until the
> Trust Plane deployment gate passed, and that runtime remained forbidden. That
> entry condition **no longer holds and must not be cited**. It bundled the
> architecture gate together with the production cutover gate; they are now
> distinct. The original text is preserved in Git history and in the
> [runtime sequencing correction](../history/0002-runtime-sequencing-correction.md).

> **Current entry condition (2026-08-04).** **The Operator Root Authority
> ceremony completed the Fabric Runtime architecture gate.** The external root
> exists as `TAUTH-000001`, established out of band by a human. Fabric Runtime
> implementation is gated on ENG-0001 and ENG-0002 being released and merged —
> **not** on TrustGateway cutover.
>
> **TrustGateway production cutover is a separate, later gate** and every one of
> its requirements is preserved unchanged: production trust store validated,
> initial migrated subjects seeded, `trust-plane-runtime` or an approved
> code-owned fallback available as the verdict source, rollback procedure
> validated, and deployment evidence retained. Runtime may be **built** now; it
> may not carry **production trust traffic** until that gate passes.

## Context

ADR-0011 ended with a sentence that was a promise as much as a description:
the Distributed Capability Fabric cannot begin until the Trust Plane exists,
because every question the fabric asks is a trust question. The Trust Plane now
exists — specified in v0.9.2, implemented in v0.9.3, and made the single
decision point in v0.9.4. So the fabric's questions can finally be asked
somewhere other than inside a scheduler.

The platform runs on one machine. The machines it does not run on are not
hypothetical: there is a workstation with a large consumer GPU, a reference
host with a small datacentre GPU, a virtualisation host with a mid-range GPU,
and an obvious future in which some capacity is rented rather than owned. Each
can do something the others cannot, and none of them should ever become the
platform.

That last clause is the whole problem. The easy version of this feature is a
cluster: nodes that find each other, agree among themselves, elect a leader,
and route work by load. Every one of those verbs moves a decision out of the
governed core and into the population of machines being governed. A cluster
that can admit its own members has replaced the Operator Root Authority with a
quorum, and a quorum is exactly the thing an attacker who owns two machines
would like to have.

There is a second, quieter problem. The platform already has a `capability`
record — `CAP-0001` through `CAP-0008` — meaning *a stated ability of the
platform*, carrying a maturity claim. That is a governance artefact. The thing
the fabric routes to is an executable unit on a particular machine. These are
different concepts that would very naturally end up sharing a word, and the
first time somebody routes a request to "LLM Routing, maturity: partial" the
confusion becomes an outage.

## Decision

The **Distributed Capability Fabric** becomes a governed layer beside
Observation, Knowledge, Integrity, Experience, Occurrence, and Trust.

> **No machine is Kyri. No model is Kyri. Kyri is the governed core, and the
> fabric is how that core borrows capacity without lending authority.**

### Three layers, three questions, one direction

| Layer | Question | May it grant eligibility? |
|---|---|---|
| **Trust Plane** (ADR-0011) | May this subject participate? | Yes — it is the only thing that may |
| **Capability Fabric** (this ADR) | Where may this capability execute? | No — it may only narrow what trust allowed |
| **Health Monitor** (v0.9.6) | Is the trusted capability inside its declared envelope? | No — it may only remove candidates |

**Trust precedes capability.** A capability that is not trusted does not
execute, however available it is. **Health never overrides trust**: where the
two disagree, trust decides, and a perfect health record cannot make a
quarantined instance usable.

The directionality rule of ADR-0011 is preserved and extended. **Reasoning may
consume trust; trust never consumes reasoning.** The fabric adds two more
things that must never produce trust:

- **A node's self-report is not trust.** A host describes its own hardware,
  packages, and readiness. The Trust Plane decides whether that description is
  believed.
- **An execution result is not trust.** A capability that has returned correct
  answers for six months has earned nothing. A compromised capability's most
  likely behaviour is to return correct answers.

Concretely: no `capability-advertisement`, `capability-instance`,
`capability-selection`, or execution outcome may be the source of a `TRUSTS`,
`VERIFIED_BY`, or `APPROVED_BY` edge.

### No new trust domain

ADR-0011 declared fifteen trust domains, two of which were reserved for exactly
this release: **`capability-package`** and **`fabric-node`**. The fabric uses
both and adds none.

This is deliberate and it is a test of ADR-0011. If defining the fabric had
required a sixteenth domain, it would have meant the trust model was being
reshaped by the feature that needed it — which is the failure mode ADR-0011
was written to prevent. It did not, so the domains stand unchanged.

Notably, an **advertisement is not a trust subject at all.** A self-report
never becomes trusted; it is either corroborated by verification and used in an
admission decision, or it is not.

### Definitions

Nine terms. Each names one thing, and the boundaries between them are what make
identity survive change.

**Capability.** An abstract, named ability, independent of code, version, host,
and hardware — "generate text", "transcribe speech", "describe an image". It is
the identity anchor: everything else in this list can change while the
capability stays the same. Recorded as a `capability-definition`. Schema:
`CAPDEF-0000`.

> **This is not the `CAP-0000` capability record.** That record states what the
> *platform* can do and carries a maturity claim; it is a governance artefact
> and nothing routes to it. A fabric capability is executable. The two are
> related — a `CAP` record may be realised by one or more fabric
> capabilities — but they are never the same record and never share an
> identifier space.

**Capability Contract.** The versioned, testable interface a capability is
reached through: request shape, response shape, failure modes, determinism
class, effect class, and an explicit list of the prior versions it is
compatible with. Contracts are what version negotiation happens against.
Schema: `CCON-0000`.

**Capability Package.** The reviewable artefact that implements a contract —
code, configuration, model reference, manifest — as a single named, versioned
thing that can be trusted or refused. **This is the trust subject**, in the
`capability-package` domain. A package is trusted independently of any machine
it might run on. Schema: `CPKG-0000`.

**Capability Host.** A machine offering execution capacity to the fabric. **The
trust subject in the `fabric-node` domain.** A host record carries the node's
declared identity, its *verified* resource profile, where it physically sits,
and the highest data classification it may ever see. It does not carry what it
is allowed to run; that is a property of the instance. Schema: `CHOST-0000`.

**Capability Advertisement.** A host's **self-report**: "I hold package P, I
satisfy contract versions V, my resources are R, as of this moment, valid until
that moment." It is a **claim, never a grant**. It confers no trust, creates no
eligibility, and cannot admit anything — including itself. An advertisement is
immutable and expires. Schema: `CADV-000000`.

**Capability Instance.** The **admitted binding** of one package to one host
for one contract, and the only thing that may be routed to. An instance exists
only where a package trusted for the contract meets a host trusted as a fabric
node, with a verified resource match, a fresh advertisement, an unexpired
admission decision, and a non-empty scope intersection. Schema: `CINST-000000`.

**Capability Route.** The declared, versioned policy binding a request class to
an **explicitly ordered list of candidate instances**, with the locality rule
and data classification the request must respect. The order is written by a
human. Schema: `CROUTE-0000`.

**Capability Selection.** One recorded act of choosing: which route and route
version applied, every candidate considered, why each excluded candidate was
excluded, which instance was chosen, and when. This is the record that answers
"why did this run there?" Immutable. Schema: `CSEL-000000`.

**Capability Health.** Whether a trusted, admitted instance is currently
available and behaving inside its declared operational envelope. **Defined here
only as an input boundary; the health model itself is v0.9.6.** The fabric's
contract with health is one sentence and it is one-directional: **health may
remove a candidate from consideration and may never add one.** A healthy
instance that is not trusted is not eligible; an unhealthy instance that is
trusted is trusted and unavailable, which is a different sentence.

### Governed discovery

**Capability discovery means one thing: governed lookup of trusted capability
advertisements already admitted into the Fabric registry.** It is a read
against the governing core, and it is not a way of finding out what exists.

The required sequence, in order:

1. A **subject is identified** — declared by an operator, never found.
2. A **trust decision exists** for it (ADR-0011).
3. The **subject is admitted** to the fabric.
4. An **advertisement is registered** — only an admitted subject may register
   one.
5. The advertisement **becomes queryable**.
6. A **route may reference** the resulting instance.
7. A **selection may choose** it.

Nothing skips a step, and nothing enters at step 4.

> **Reachability never implies admission.** A machine that answers on the
> network has demonstrated that it is on the network, and nothing else.

Explicitly forbidden:

- **No network scanning** and **no subnet scanning.**
- **No multicast discovery** and **no broadcast discovery.**
- **No unsolicited advertisements** — one from an unadmitted subject is not a
  pending application; it is not a record at all.
- **No automatic registration** and **no automatic node admission.**
- **No trusting an advertisement based on reachability.**
- **No advertisement modifying trust state**, in either direction.
- **No DNS discovery as trust** — a name that resolves is a name that resolves.
- **No service discovery that bypasses the registry.**

### How nodes discover capabilities

**They do not.** Discovery in the peer-to-peer sense does not exist in this
architecture, and its absence is the design.

- A host **publishes an advertisement to the governing core**, and learns
  nothing in return about any other host.
- A consumer **reads the core's registry of admitted instances**. That registry
  is the only place capabilities are discoverable, and it contains only what
  has been admitted.
- Hosts never see each other, never exchange capability information, and never
  form a membership view.

**No broadcast, no multicast, no gossip, no mDNS, no service mesh, no peer
discovery, no automatic node registration.** A node that appears on the network
and announces itself has achieved nothing: an advertisement from an unknown
host is a claim from an unknown host, and `Unknown` fails closed.

The absence of an advertisement means the capability is **absent**, not
"probably still there". A fabric that assumes continuity has invented state it
does not have.

### How capabilities are trusted

Trust is **composed by intersection, never inherited**.

An instance is eligible only when **all eight** conditions hold:

1. The **package** holds `Trusted` or `Restricted` in the `capability-package`
   domain, for this contract.
2. The **host** holds `Trusted` or `Restricted` in the `fabric-node` domain.
3. The package **declares** it satisfies the requested contract version.
4. The host's **verified** resource profile satisfies the package's declared
   requirements.
5. A **fresh advertisement** exists — present and inside its validity window.
6. An **admission decision** exists, is human-approved, and has not expired.
7. The **effective scope** — the intersection of package scope, host scope, and
   admission scope — is non-empty.
8. The request's **data classification** does not exceed the host's ceiling.

Any one missing makes the instance **ineligible**. The default is ineligible;
absence of a record is never permission.

The composition rule matters more than the list:

> **Trusting a package trusts no machine. Trusting a machine trusts no package.
> An instance is trusted only where both are, and only in the intersection of
> their scopes.**

A model package approved for summarisation, running on a host restricted to
observation workloads, yields an instance that may do neither — the
intersection is empty, so nothing is eligible. That is the correct and
deliberately inconvenient answer.

**No self-admission.** A host cannot admit itself, widen its own scope, trust
another host, or accept work the core did not route to it.

### How routing occurs

Routing is a **deterministic, total, and explainable function** of declared
inputs. The same inputs choose the same instance, every time, and the choice
can be reconstructed from records.

1. Resolve the **route** for the request class — capability, contract version
   range, data classification, locality. **No route → refuse.**
2. Reduce the route's candidate list to the **eligible** instances, by the
   eight conditions above.
3. Allow **health to remove** further candidates. Health may not reorder or add.
4. Select the **first remaining candidate in the declared order**.
5. If none remain, **refuse**, naming every candidate and why it was excluded.
6. Write a **capability-selection** record.

**No load-based routing, no latency-based routing, no score-based routing, no
weighting, no automatic scaling.** Ordering is written by a human and stored in
the route. A router that orders candidates by observed behaviour is deriving
placement from reasoning, which is the ADR-0011 directionality violation
wearing an operations hat — and it is also unpredictable during the incident
when prediction matters most.

`locality` is enforced, not advisory. A `local-only` request **must refuse
rather than leave the host**. Degrading to a remote instance because the local
one is unavailable is precisely the silent redirection this rule exists to
prevent.

### How capability loss is handled

Loss is any transition from eligible to ineligible: revocation, quarantine,
expiry of any clock, drain, host disappearance, health failure, or an
advertisement going stale.

- The route falls to the **next declared candidate**, in order.
- If no declared candidate remains, the fabric **refuses**, with a reason
  naming each candidate and its exclusion.
- **No automatic failover outside the declared candidate list.** A host that
  was never named in the route never receives the work, however capable and
  however idle.
- **No automatic remediation** — no restart, no re-admission, no
  re-advertisement acceptance, no drain, no quarantine, no trust change.
- Loss produces an **audit event**. Silence is not an outcome.

**Recovery is a decision, not an event.** A host that comes back is not thereby
eligible: if its admission or trust expired while it was gone, it returns as
what it now is, which is untrusted.

### How version negotiation works

Negotiation happens against **contracts**, never packages, and it is set
intersection with no cleverness in it.

- A request declares a contract and an **explicit set of accepted versions**.
- A package declares the **explicit set of contract versions it satisfies**.
- The eligible set is the intersection. **Empty → refuse.**

**Compatibility is declared, never inferred.** A contract names the prior
versions it is compatible with, in a field, reviewed by a human. The platform
never reads meaning into a version number: semantic-versioning arithmetic is a
convention publishers follow imperfectly, and treating it as a guarantee means
an upgrade decision gets made by string comparison.

**No automatic upgrade, no automatic downgrade, no nearest match, no
best-effort.** A request that cannot be satisfied exactly is refused.

### How governance remains centralized

One registry, one policy set, one Trust Plane, one audit timeline — **all on
the governing core**.

> **Hosts execute. Hosts never decide.**

A capability host may not:

- admit itself or any other host, or register a node
- create, modify, or reorder a route
- grant, widen, or extend its own scope
- extend an admission or a validity window
- accept work the core did not route to it
- exchange capability, trust, or membership information with another host

Node-local state is a **cache, never an authority**. If the core is
unreachable, hosts do not continue autonomously — a fabric that keeps operating
without governance has moved the boundary to wherever the network happens to
partition.

**No quorum, no leader election, no consensus, no shared cluster state.** These
are the mechanisms by which a population of machines governs itself, and the
platform is not governed by the machines it governs.

### How trust decisions flow

One direction, terminating outside the platform:

```
Operator Root Authority  (external, human, out of band)
  → Trust Authority
    → Trust Decision
      → Trust Record        (capability-package | fabric-node)
        → Capability Instance eligibility
          → Capability Route
            → Capability Selection
              → execution
```

Nothing flows back up. An execution result, a health signal, an advertisement,
a latency measurement, or a model's own output may **never** produce, raise, or
restore a trust state. Follow any `APPROVED_BY` edge far enough and it ends at
the Operator Root Authority, which is external to Kyri and never created,
approved, or modified by it.

### How capabilities expire

**Three independent clocks. Each fails closed. None auto-renews.**

| Clock | Governs | On lapse |
|---|---|---|
| **Trust expiry** | package and host trust records | state becomes `Expired` (ADR-0011); instance ineligible |
| **Advertisement validity** | the host's claim about itself | claim is stale; instance ineligible |
| **Admission expiry** | the instance binding itself | binding lapses; instance ineligible |

Any one lapsing is sufficient to make the instance ineligible. Crucially, **a
fresh advertisement does not revive an expired admission or an expired trust
record.** Otherwise a host could keep itself eligible indefinitely by talking,
which is auto-renewal with extra steps.

Re-eligibility after any expiry requires a **new decision**.

### How capability supersession works

A **new package version is a new subject.** It requires its own trust decision,
with its own evidence — ADR-0011 forbids automatic capability approval, and
"it is version 1.4.1 of something we already trust" is exactly the automatic
approval it forbids.

- Supersession is **declared**, on the record, never inferred from a version
  number or an installation event.
- The old and new instances **may coexist** during a declared overlap.
- **Cutover is a route change** — a new route version listing the new
  instance — not a package event. A package cannot promote itself.
- Superseded records **remain readable**. Nothing is edited.

### How capability identity survives host migration

Because identity is **layered**, and each layer survives changes to the ones
below it:

| Identity | Survives |
|---|---|
| **Capability** (`CAPDEF`) | contract version changes, package changes, host changes, hardware changes |
| **Contract** (`CCON`) | package changes, host changes |
| **Package** (`CPKG`) | host changes, hardware changes |
| **Instance** (`CINST`) | nothing — it is bound to exactly one host and dies with it |

Consumers name a **capability and an accepted contract version range**. They
never name a host, an instance, or a package.

So moving a capability from one machine to another destroys the instance and
nothing else. The new host publishes an advertisement, an admission decision is
made, a new instance exists, and the route is updated to list it. The capability
identifier never changed, the consumer never knew, and the audit trail shows
exactly when the binding moved and who approved it.

### How one capability executes on multiple hosts

As **N instances of the same package on N hosts** — nothing more exotic.

Each instance is separately advertised, separately admitted, separately
trusted, and separately eligible. The route lists them in explicit human-written
order. There is **no cluster**: no shared state, no leader, no quorum, no
replication, no coordination between the hosts, and no awareness among them
that the others exist.

Distribution across instances, if it is ever wanted, must arrive as a
**declared, deterministic rule in a route** — never as a load measurement. That
rule is not defined in this release, because nothing executes yet and inventing
a distribution policy for zero traffic would be guessing.

### How heterogeneous hardware is represented

As a **controlled vocabulary of capability-relevant attributes**, declared per
host and expressed in terms no vendor owns:

| Attribute | Meaning |
|---|---|
| `accelerator_class` | `none`, `integrated-gpu`, `discrete-gpu`, `dedicated-accelerator`, `remote-service` |
| `accelerator_memory_mb` | usable accelerator memory |
| `accelerator_compute_capability` | opaque vendor string, compared only by declared match rules |
| `host_memory_mb`, `host_cpu_cores`, `architecture` | the machine itself |

A **package declares its requirements in the same vocabulary**. Matching is
containment: every declared requirement must be satisfied by the host's
**verified** profile — not by the advertised one, because the advertised
profile is a self-report and the whole point is that self-reports are claims.

`accelerator_compute_capability` is deliberately opaque. Ordering vendor
capability strings numerically is the kind of inference that works until the
generation where it does not.

**No host, GPU, or vendor is named anywhere in the schemas, the ontology, or
any rule.** The workstation with the large consumer GPU, the reference host
with the datacentre GPU, and the virtualisation host with the mid-range GPU are
three `capability-host` records with different attribute values. A future cloud
node is a fourth record with `accelerator_class: remote-service`,
`location_class: third-party-hosted`, and a lower
`data_classification_ceiling` — same shape, no special case, no new code.

### Effect classes, and the door held open for robotics

Every contract declares an **effect class** — what the capability changes,
which is the axis governance cares about. It is separate from determinism: a
deterministic capability can still change the world, and a nondeterministic one
need not.

| Class | Meaning | Routable? |
|---|---|---|
| **`read-only`** | Observes; changes nothing. | Yes, subject to trust and contract |
| **`computational`** | Computes; changes nothing outside the request. | Yes, subject to trust and contract |
| **`content-generating`** | Produces new content; changes nothing outside the request. | Yes, subject to trust and contract |
| **`side-effecting`** | Changes state outside the request. | **No — unroutable in v0.9.5** |

**`side-effecting` is representable but unroutable.** No route may select it,
no selection may choose it, and **no route may override the prohibition** — a
restriction that can be lifted per-route is one that gets lifted during an
incident.

The class exists so that a future actuating capability — robotics, physical
control, anything that moves — is *representable* without being *permitted*.
Admitting actuation under governance written for text generation is how a
capability fabric becomes an autonomous controller, and it would happen in a
single pull request that looked like adding a model.

**Future enablement requires all six of:**

1. a **new ADR** governing actuation on its own terms
2. an explicit **approval model**
3. **effect authorization** — per-effect, not per-capability
4. **remediation boundaries** — what may be undone, and by whom
5. **audit requirements** for effects that reached the world
6. **human approval semantics** — what a human is approving, and when

Naming the price here is what stops it being paid by accident.

### Trust, Fabric, and Health

Three layers, three questions, and the separation between them is load-bearing.

| Layer | Question |
|---|---|
| **Trust** | May this subject participate? |
| **Fabric** | Where may this workload execute? |
| **Health** (v0.9.6) | Is the trusted capability currently available and operating within its declared limits? |

The rules, stated individually because each is a different way the separation
gets eroded:

- **Trust precedes admission.** Nothing is admitted that is not first trusted.
- **Health cannot grant trust.**
- **Health cannot override quarantine.** A quarantined subject with a perfect
  health record stays quarantined.
- **Health cannot broaden scope.**
- **Health cannot admit a node.**
- **Fabric cannot create trust decisions.**
- **Fabric cannot mutate trust state.**
- **The Trust Plane does not use routing outcomes as evidence of
  trustworthiness.** A capability that has been selected and has returned
  correct answers for six months has earned nothing; a compromised capability's
  most likely behaviour is to return correct answers.

The Capability Health Monitor remains v0.9.6, and **no health implementation
appears in this sprint**. Until it exists, health is *declared or unknown*, and
unknown stays unknown — treating missing data as healthy is how an unmonitored
node becomes the preferred one.

### The core carries no capability semantics

The fabric knows about contracts, packages, hosts, instances, routes, and
selections. **It never knows what a capability does.** That is what makes the
following all record changes rather than core changes:

| Adding | Requires |
|---|---|
| a local **Ollama** model | a package implementing an existing text-generation contract |
| a **cloud LLM** | the same, on a host with `location_class: third-party-hosted`, behind the ADR-0003 gateway contract |
| a **vision** engine | a new contract and a package; no core change |
| a **code** model | a package against the text-generation contract |
| **speech** | a new contract and a package; no core change |
| future **robotics** | a `side-effecting` contract, which no route may select until a future ADR permits it |

ADR-0003 is preserved exactly: model endpoints are reached through the gateway
contract, not as direct provider dependencies, and there is no automatic
commercial-provider fallback — a cloud instance is a declared candidate in a
route or it is nothing.

### Audit requirements

The fabric's records are the reason a distributed system stays reviewable.
Every one of the following is immutable, append-only, and superseded rather
than edited:

- **Every advertisement** — what a host claimed about itself, and when.
- **Every admission decision** — who approved this binding, on what evidence,
  and until when.
- **Every selection** — the route and route version, all candidates considered,
  the exclusion reason for each rejected one, the instance chosen.
- **Every loss and refusal** — what became ineligible, why, and what was
  refused as a result.
- **Every supersession** — what replaced what, and when the overlap ended.

Two questions must be answerable from records alone, without reconstructing
anything from logs: **"why did this run there?"** and **"what was this machine
allowed to do in March?"**

### Explicitly forbidden

Each is individually convenient. That is why each is named.

- **No automatic node registration** — a machine on the network has no standing.
- **No trust on first advertisement** — this is **trust on first use** with a
  new spelling, and it is forbidden for the same reason.
- **No self-admission** — no host admits itself or another.
- **No peer discovery** — no gossip, broadcast, multicast, mDNS, or mesh.
- **No load-based routing** — nor latency-based, score-based, or weighted.
- **No automatic failover outside the declared candidate list.**
- **No automatic remediation** — no restart, drain, re-admission, or requeue.
- **No automatic trust change of any kind**, in either direction.
- **No prediction** — no forecasting of capacity, availability, or demand.
- **No quorum, no leader election, no consensus, no shared cluster state.**
- **No capability inference from behaviour** — a host that answers a request
  well has not demonstrated a capability.
- **No credential material in any fabric record.**
- **No capability becoming the platform** — no instance is Kyri.

## Rejected Alternatives

**A cluster with peer discovery.** The standard answer, and it would work on
the first day. It also means membership is decided by the members, which
replaces an external human root with an internal quorum. The moment two nodes
can vouch for a third, the Operator Root Authority is advisory.

**A scheduler with a cost model.** Placement by measured load, latency, or
queue depth — the obvious way to use heterogeneous hardware well. It makes
placement a function of observed behaviour, which is the ADR-0011 directionality
violation, and it makes placement unpredictable exactly when an operator is
trying to work out why something ran somewhere. Declared order is worse at
utilisation and better at being understood.

**Capability scores.** A number per instance, computed from success rate and
latency, used to rank candidates. Rejected for the same reason ADR-0011
rejected trust scores: a threshold nobody chose becomes the operational
boundary, and an instance can raise its own score by behaving well until the
moment it matters.

**Semantic-versioning-implied compatibility.** Let a minor version bump be
automatically compatible. Ninety-nine times in a hundred it is. The hundredth
is an upgrade nobody approved, authorised by a string comparison.

**Workload leases as the primary abstraction.** The roadmap reserved them, and
they are a good fit for a running scheduler. There is no scheduler in this
release, so a lease would be an entity describing the lifetime of an execution
that cannot occur. Deferred until there is something to lease.

**Health-aware automatic failover.** The most tempting item on this list,
because it is what every operator wants at 3am. It makes availability data —
the easiest signal in the platform to manipulate from outside — into a
placement authority. Health may remove a candidate; the declared order decides
what happens next.

**A capability registry on each node, federated.** Scales beautifully and means
there is no single answer to "what does this platform have". Governance would
be distributed by construction, which is the one property this architecture
exists to refuse.

**Reusing the `CAP-0000` capability record for fabric capabilities.** One
concept, one word, less vocabulary — genuinely attractive under a simplicity
rule. It would mean a maturity claim about the platform and a routable
executable unit share an identifier space, and the first person to route to a
`planned` capability discovers the difference in production.

**Trusting the advertised resource profile.** Verifying hardware out of band is
tedious and the host is right about its own GPU essentially always. It is also
the one field an attacker would edit to attract workloads to a machine they
control.

**Building the fabric runtime in this release.** The schemas exist and the
design is written; implementation would be weeks, not months. A partially built
fabric reads as a control while behaving as a suggestion, and the layers above
would start depending on guarantees it does not make. Architecture ships first,
deliberately — as it did for the Trust Plane, for the same reason.

## Consequences

**Positive.** The platform can describe capacity it does not own without
lending it authority. Capability identity is stable across host migration,
hardware replacement, and package upgrade, so consumers are insulated from the
churn that motivated the fabric in the first place. "Why did this run there?"
has a record-based answer. ADR-0011's fifteen trust domains absorbed the entire
feature without change, which is meaningful evidence the trust model was built
at the right altitude. v0.9.6 gets a set of entities to observe, and a
one-directional contract with them.

**Negative.** Adding a machine is now genuinely laborious: a host record, an
out-of-band identity verification, a verified resource profile, a trust
decision, an advertisement, an admission decision, and a route edit. Nothing
about that is fast, and there is no fast path by design. Declared-order routing
will underuse hardware compared with any load-aware scheduler. Every new
capability requires a contract before it requires code.

**The architecture gate was not opened by this specification.** It was opened
later, by the Operator Root Authority ceremony, which established the external
root out of band. Fabric Runtime implementation now waits only on the
independently released ENG-0001 and ENG-0002 defect fixes.

**The production cutover gate is untouched by that.** A fabric node may be
built against this specification; it may not carry production trust traffic
until the TrustGateway cutover gate passes with its subjects seeded, its verdict
source confirmed, its rollback validated, and its evidence retained. Building
the runtime and trusting it in production are two different permissions, and
this ADR grants only the first.

**Accepted risks.**

- **A specification is not a control.** Nothing in this release enforces any of
  it. The static suite asserts the specification is complete and that no
  partial implementation has appeared.
- **Eight entity types is a large vocabulary for zero runtime.** Each exists to
  make one identity survive one kind of change, and the separations were chosen
  before any of them had a consumer. Some may prove to be one distinction too
  many; a later ADR can merge them, and merging is easier than splitting a
  record type that conflated two things.
- **Declared-order routing may prove operationally impractical** at a scale
  this platform has not reached. A deterministic distribution rule can be added
  to a route later without changing the layer.
- **The `side-effecting` effect class is defined but unusable.** It may turn out
  to be the wrong shape for actuation entirely. Defining it costs a field;
  discovering the need for it after robotics arrives costs the governance.
- **Advertisement freshness windows are unenforced** until a runtime exists,
  like every other guarantee here.

## Related

- [ADR-0003: Provider-Agnostic AI Architecture](ADR-0003-provider-agnostic-ai-architecture.md)
- [ADR-0010: Remote Read-Only Collection](ADR-0010-remote-read-only-collection.md)
- [ADR-0011: The Trust Plane](ADR-0011-trust-plane.md)
- [Capability Fabric overview](../fabric/capability-fabric.md)
- [Capability lifecycle](../fabric/capability-lifecycle.md)
- [Capability identity](../fabric/capability-identity.md)
- [Capability routing](../fabric/capability-routing.md)
- [Node model and heterogeneous hardware](../fabric/node-model.md)
- [Failure behaviour](../fabric/failure-behaviour.md)
- [Governance boundaries](../fabric/governance-boundaries.md)
