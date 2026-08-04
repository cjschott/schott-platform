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

## Two gates, deliberately kept apart

There are **two** gates, and collapsing them is the mistake this section exists
to prevent. One governs whether the Fabric Runtime may be **built**. The other
governs whether it may **carry production trust traffic**.

**TrustGateway cutover is intentionally not the Fabric Runtime gate.** The
Operator Root ceremony was.

### Gate 1 — Fabric Runtime entry gate

1. **Operator Root Authority ceremony complete.** Satisfied: the external root
   exists as `TAUTH-000001`, established out of band by a human.
2. **ENG-0001 released** — the root establishment lineage contract implemented
   test-first, independently reviewed and merged.
3. **ENG-0002 released** — `validate-store` made genuinely read-only,
   independently reviewed and merged.

Both defect fixes must merge before Fabric Runtime implementation begins.

### Gate 2 — TrustGateway production cutover gate

1. **Fabric Runtime validated.**
2. **Health Runtime validated.**
3. **initial subjects seeded.**
4. **verdict source ready.**
5. **rollback validated.**
6. **deployment evidence retained.**
7. **TrustGateway cutover** performed as the final production transition.

Its requirements are preserved in full and unchanged:

- **Operator Root Authority instantiated** from an external identity, out of
  band, by a human.
- **production trust store validated** — structurally clean, correct ownership
  and permissions, outside the repository.
- **initial migrated subjects seeded** — collector plugins, source types,
  remote targets, remote operations, host identity, policy version, and gateway
  configuration.
- **trust-plane-runtime or approved code-owned fallback available** as the named
  verdict source for every migrated request, with no silent fallback.
- **rollback procedure validated** as configuration rollback, never
  trust-history rollback.
- **deployment evidence retained** — exit codes, identifiers, fingerprints,
  audit events, permissions, and before/after repository state.

## What Gate 1 permits, and what it does not

Gate 1 permits **construction**. It does not permit production operation, and
the distinction is not cosmetic: a node admitted while the gateway still answers
from code-owned policy is a node trusted through a chain that does not terminate
at the root.

**Permitted after Gate 1:**

- **Runtime implementation** — the fabric engine may be built.

**Still prohibited until Gate 2 passes — in production:**

- **Node admission in production** — no production host enters the fabric.
- **Capability registration in production** — no production advertisement is
  registered.
- **Routing in production** — no production route is resolved.
- **Selection in production** — no production candidate is chosen.
- **Execution in production** — nothing runs against production trust.

Development and test fixtures are not production. A fixture that admits a
synthetic node inside a temporary store is construction; the same call against
the production trust store is not.

See the [runtime sequencing correction](../history/0002-runtime-sequencing-correction.md),
[deployment guide](../trust/operator-root-authority-deployment.md), and
[validation checklist](../trust/operator-root-authority-validation-checklist.md).

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability routing](capability-routing.md)
- [Failure behaviour](failure-behaviour.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Trust domains](../trust/trust-domains.md)
