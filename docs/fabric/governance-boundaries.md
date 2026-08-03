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

## The deployment gate

**Specification may proceed before Operator Root deployment acceptance.**
Writing this architecture does not open the gate.

**Blocked until the Trust Plane deployment gate passes:**

- **Runtime implementation** — no fabric engine of any kind
- **Node admission** — no host enters the fabric
- **Capability registration** — no advertisement is registered
- **Routing** — no route is resolved
- **Selection** — no candidate is chosen
- **Execution** — nothing runs anywhere

A fabric node trusted through a chain terminating inside the platform is not
trusted at all, which is why none of the above may begin first.

**The gate requires all seven:**

1. **Operator Root Authority instantiated** from an external identity, out of
   band, by a human.
2. **production trust store validated** — structurally clean, correct ownership
   and permissions, outside the repository.
3. **initial migrated subjects seeded** — collector plugins, source types,
   remote targets, remote operations, host identity, policy version, and
   gateway configuration.
4. **TrustGateway source confirmed as `trust-plane-runtime`** for every
   migrated request.
5. **no migrated request using code-owned fallback.**
6. **rollback procedure validated** as configuration rollback, never
   trust-history rollback.
7. **deployment evidence retained** — exit codes, identifiers, fingerprints,
   audit events, permissions, and before/after repository state.

Architecture is allowed now. Runtime remains forbidden.

See the [deployment guide](../trust/operator-root-authority-deployment.md) and
[validation checklist](../trust/operator-root-authority-validation-checklist.md).

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability routing](capability-routing.md)
- [Failure behaviour](failure-behaviour.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Trust domains](../trust/trust-domains.md)
