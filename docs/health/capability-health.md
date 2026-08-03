# The Capability Health Plane

**Architecture only.** Nothing described here is implemented. There is no
health engine, no collectors, no probes, no heartbeat receiver, and no
evaluation loop. This document explains the architecture defined in
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

## What it is for

v0.9.5 defined *where* a capability may execute. It could not say whether the
thing it selected was working.

If the first candidate in a route is trusted, admitted, and silently broken,
the fabric selects it every time and the only signal is that requests fail. The
Health Plane exists to answer one question, and only that question:

> **Is this trusted capability available and behaving within its declared
> operational envelope?**

> **Health never grants trust, and trust never implies health.**

## Two axes, not one scale

A subject may be **trusted and healthy**, **trusted and degraded**, **trusted
and unavailable**, or **restricted and healthy**.

- A **quarantined** subject cannot be made usable by any health status, however
  good.
- An **untrusted** subject cannot be made eligible by excellent health.

**Health must never override trust. Where the two disagree, trust decides.**

## Three layers

| Layer | Question | May it grant eligibility? |
|---|---|---|
| **Trust Plane** (ADR-0011) | May this subject participate? | Yes — only it may |
| **Capability Fabric** (ADR-0012) | Where may this workload execute? | No — it narrows |
| **Health Plane** (ADR-0013) | Is the trusted capability inside its declared limits? | No — it may only remove, on evidence |

## The six records

| Record | Identifier | What it is |
|---|---|---|
| **Health Envelope** | `CHENV-0000` | Declared per-dimension limits. **Human-authored, never learned.** |
| **Heartbeat** | `CHBEAT-000000` | A subject's liveness claim about itself. **Confers nothing.** |
| **Health Observation** | `CHOBS-000000` | One measurement. **Evidence, carrying no verdict.** |
| **Health State** | `CHSTATE-000000` | Deterministic derived standing, citing its observations. |
| **Degradation Event** | `CHDEG-000000` | A recorded transition. **Observed history, never the future.** |
| **Health Recommendation** | `CHREC-000000` | Asks a human to investigate or drain. **Never an act.** |

## The shape of the thing

```
Envelope (CHENV)          declared limits, per dimension    ── human-authored
  │
  ├── Observation (CHOBS)  one measurement, one moment      ── evidence
  │     └── Heartbeat (CHBEAT)  liveness claim              ── a claim
  │
  └── Health State (CHSTATE)   deterministic, cites evidence
        ├── Degradation Event (CHDEG)   recorded transition
        └── Recommendation (CHREC)      asks a human
```

Nothing in that diagram executes. The rightmost thing the layer can produce is
a record asking a person to look.

## What it may never do

- **grant trust**, or change trust state in either direction
- **override quarantine**, broaden scope, or admit a node
- **reroute, drain, quarantine, restart, or remediate** anything
- **predict or forecast** availability, capacity, or demand
- **learn a threshold** from a subject's own behaviour
- **produce a health score**
- **conclude anything about a subject it could not reach**

A monitor that reroutes, drains, or quarantines on its own is an autonomous
controller wearing an observability label — the same mistake ADR-0010 refused
for remote collection, two layers up.

## Related

- [ADR-0013: The Capability Health Plane](../decisions/ADR-0013-capability-health-plane.md)
- [Health states](health-states.md)
- [Observation model](observation-model.md)
- [Operational envelope](operational-envelope.md)
- [Degradation semantics](degradation-semantics.md)
- [Governance boundaries](governance-boundaries.md)
- [Capability Fabric overview](../fabric/capability-fabric.md)
