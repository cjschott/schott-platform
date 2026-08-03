# The Distributed Capability Fabric

**Architecture only.** Nothing described here is implemented. There is no
fabric engine, no registry service, no scheduler, no placement, no networking,
and no execution. This document explains the architecture defined in
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md); the ADR and
the eight schemas are the specification.

## What it is for

The platform runs on one machine. Other machines can do things this one cannot:
a workstation with a large consumer GPU, a virtualisation host with a mid-range
one, and eventually capacity that is rented rather than owned.

The fabric is how the governed core borrows that capacity **without lending it
authority**.

> **No machine is Kyri. No model is Kyri.**

The easy version of this feature is a cluster: nodes that find each other,
agree among themselves, elect a leader, and route work by load. Every one of
those verbs moves a decision out of the governed core and into the population
of machines being governed. This architecture refuses all four.

## Three layers, three questions

| Layer | Question | May it grant eligibility? |
|---|---|---|
| **Trust Plane** (ADR-0011) | May this subject participate? | Yes — only it may |
| **Capability Fabric** (ADR-0012) | Where may this capability execute? | No — it only narrows |
| **Health Monitor** (v0.9.6) | Is it inside its declared envelope? | No — it only removes |

**Trust precedes capability.** **Health never overrides trust.** A quarantined
instance with a perfect health record is not usable, and a trusted instance
that is unavailable is trusted and unavailable — which is a different sentence,
and an operator needs both halves during an incident.

## The nine concepts

| Concept | Record | What it is |
|---|---|---|
| **Capability** | `CAPDEF-0000` | An abstract named ability. The identity anchor. |
| **Capability Contract** | `CCON-0000` | The versioned interface it is reached through. |
| **Capability Package** | `CPKG-0000` | The reviewable artefact implementing a contract. **Trust subject.** |
| **Capability Host** | `CHOST-0000` | A machine offering capacity. **Trust subject.** |
| **Capability Advertisement** | `CADV-000000` | A host's self-report. **A claim, never a grant.** |
| **Capability Instance** | `CINST-000000` | The admitted binding. **The only routable thing.** |
| **Capability Route** | `CROUTE-0000` | Declared, ordered candidate list. |
| **Capability Selection** | `CSEL-000000` | One recorded act of choosing. |
| **Capability Health** | *(v0.9.6)* | Whether an admitted instance is inside its envelope. |

### This is not the `CAP-0000` capability record

The platform already has a `capability` record — `CAP-0001` through
`CAP-0008` — meaning *a stated ability of the platform*, carrying a maturity
claim. That is a governance artefact and **nothing routes to it**.

A fabric capability is executable. A `CAP` record may be *realised by* one or
more fabric capabilities, but they are never the same record and never share an
identifier space. See the
[Capability Model Standard](../standards/capability-model-standard.md).

## How the pieces fit

```
Capability (CAPDEF)          what can be done, abstractly
  └── Contract (CCON)        how it is called, versioned
        └── Package (CPKG)   what implements it        ── trusted
              └── Instance (CINST)  package ⊗ host     ── admitted
                    ├── Host (CHOST)                    ── trusted
                    └── Advertisement (CADV)            ── claimed, expires
Route (CROUTE)               ordered candidates
  └── Selection (CSEL)       one recorded choice
```

Consumers name a **capability and an accepted contract version range**. They
never name a host, an instance, or a package — which is why moving work between
machines is invisible to them.

## No new trust domain

ADR-0011 declared fifteen trust domains and reserved two for exactly this
release: **`capability-package`** and **`fabric-node`**. The fabric uses both
and adds none.

That is a test of ADR-0011 as much as a property of the fabric. Had the fabric
needed a sixteenth domain, it would have meant the trust model was being
reshaped by the feature that needed it — the failure mode ADR-0011 exists to
prevent.

An **advertisement is not a trust subject at all**. A self-report never becomes
trusted.

## The deployment gate still holds

Writing this specification does not open the Operator Root Authority deployment
gate. **Implementation of the fabric remains blocked** until it passes, because
a fabric node trusted through a chain terminating inside the platform is not
trusted at all.

This is the same sequence the Trust Plane followed: architecture first,
deliberately, so the thing being governed does not shape its own governance.

## Related

- [ADR-0012: The Distributed Capability Fabric](../decisions/ADR-0012-distributed-capability-fabric.md)
- [Capability lifecycle](capability-lifecycle.md)
- [Capability identity](capability-identity.md)
- [Capability routing](capability-routing.md)
- [Node model and heterogeneous hardware](node-model.md)
- [Failure behaviour](failure-behaviour.md)
- [Governance boundaries](governance-boundaries.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
