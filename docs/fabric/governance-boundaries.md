# Governance Boundaries

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md).

The fabric spans machines. Governance does not.

> **Hosts execute. Hosts never decide.**

## What lives on the governing core

One of each, and all of them central:

- **one registry** of capabilities, contracts, packages, hosts, and admitted
  instances
- **one policy set**
- **one Trust Plane**
- **one audit timeline**

Node-local state is a **cache, never an authority**. If the core is
unreachable, hosts do not continue autonomously — a fabric that keeps operating
without governance has moved the boundary to wherever the network happens to
partition.

## What a capability host may never do

- admit itself, admit another host, or register a node
- create, modify, or reorder a route
- grant, widen, or extend its own scope
- extend an admission or a validity window
- accept work the core did not route to it
- exchange capability, trust, or membership information with another host

**No quorum, no leader election, no consensus, no shared cluster state.** These
are the mechanisms by which a population of machines governs itself, and the
platform is not governed by the machines it governs. The moment two nodes can
vouch for a third, the Operator Root Authority is advisory.

## Discovery does not exist

Hosts never discover each other.

- A host **publishes an advertisement to the core** and learns nothing in
  return about any other host.
- A consumer **reads the core's registry of admitted instances**, which is the
  only place capabilities are discoverable.
- Hosts never form a membership view.

**No broadcast, no multicast, no gossip, no mDNS, no service mesh, no peer
discovery, no automatic node registration.**

## Trust flows one direction

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
restore a trust state.

Follow any `APPROVED_BY` edge far enough and it ends at the **Operator Root
Authority**, which is external to Kyri and never created, approved, or modified
by it.

**A node's self-report is not trust.** **An execution result is not trust.** A
capability that has returned correct answers for six months has earned nothing;
a compromised capability's most likely behaviour is to return correct answers.

## Audit requirements

Every one of the following is immutable, append-only, and superseded rather
than edited:

| Record | Answers |
|---|---|
| **Every advertisement** | What did this host claim about itself, and when? |
| **Every admission decision** | Who approved this binding, on what evidence, until when? |
| **Every selection** | Which route version applied, what was considered, why was each candidate excluded? |
| **Every loss and refusal** | What became ineligible, why, and what was refused as a result? |
| **Every supersession** | What replaced what, and when did the overlap end? |

Two questions must be answerable **from records alone**, without reconstructing
anything from logs:

- **"Why did this run there?"**
- **"What was this machine allowed to do in March?"**

A distributed system that cannot answer the second one has no governance; it
has a deployment.

## Discovery is a governed lookup

Capability discovery means **governed lookup of trusted capability
advertisements already admitted into the Fabric registry**. An advertisement
becomes **queryable** only after its subject has been admitted; before that it
is not a pending record, it is not a record at all.

**Reachability never implies admission.**

## The runtime and production-transition gates

The Operator Root Authority ceremony completed the architectural gate for
Fabric Runtime. Fabric implementation is not gated by TrustGateway cutover.

The corrected dependency sequence is:

1. **Operator Root Authority ceremony completed.**
2. **ENG-0001** persists allocated TLIN lineage records and is independently
   reviewed, released, and merged.
3. **ENG-0002** makes `validate-store` genuinely read-only and is independently
   reviewed, released, and merged.
4. **Fabric Runtime** is implemented and validated incrementally.
5. **Health Runtime** is implemented and validated against the Fabric.
6. **subject seeding** establishes the production subjects required for
   cutover.
7. **TrustGateway cutover** is the final production transition.

Both defect fixes must merge before Fabric Runtime implementation begins. Node
admission, capability registration, routing, selection, and execution remain
subject to the trust and governance rules in this architecture, but their
implementation no longer waits for production gateway traffic to move away
from code-owned policy.

Cutover still requires the acceptance evidence, rollback procedure, seeded
subjects, `trust-plane-runtime` verdict source, and absence of silent fallback
defined by the deployment guide and validation checklist.

See the [runtime sequencing correction](../history/0002-runtime-sequencing-correction.md),
[deployment guide](../trust/operator-root-authority-deployment.md), and
[validation checklist](../trust/operator-root-authority-validation-checklist.md).

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability routing](capability-routing.md)
- [Failure behaviour](failure-behaviour.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Trust domains](../trust/trust-domains.md)
