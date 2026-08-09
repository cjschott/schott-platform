# Failure Behaviour

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md).

The fabric's answer to almost every failure is the same: **refuse, explain, and
record.** That is a deliberate choice against the more helpful-looking
alternative, which is to quietly find somewhere else to run.

## What capability loss is

Any transition from eligible to ineligible:

- trust revoked or quarantined
- any of the three expiry clocks lapsing
- the host set to `draining` or `withheld`
- the host disappearing
- health reporting the instance outside its envelope
- the advertisement going stale

All of these are the same event to the fabric, and none of them is special.

## What happens

1. The route falls to the **next declared candidate**, in the written order.
2. If no declared candidate remains, the fabric **refuses**, with a reason
   naming each candidate and its exclusion.
3. A `capability-selection` record is written **including the refusal**.
4. An audit event is recorded.

**No automatic failover outside the declared candidate list.** A host that was
never named in the route never receives the work, however capable and however
idle it happens to be. The candidate list is the complete set of places this
request may ever run.

## No automatic remediation

None of the following occurs:

- no restart, no redeploy, no requeue
- no re-admission
- no acceptance of a fresh advertisement as a recovery signal
- no automatic drain
- no automatic quarantine
- no trust change of any kind, in either direction
- no retry that silently changes the selection

A fabric that reroutes, drains, or re-admits on its own is an autonomous
controller wearing an availability label — the same mistake ADR-0010 refused
for remote collection and v0.9.6 refuses for health, one layer over.

## Recovery is a decision, not an event

A host that comes back is **not thereby eligible**. If its admission or its
trust expired while it was gone, it returns as what it now is, which is
untrusted.

Nothing returns to a usable state because the condition that removed it stopped
being visible. This is ADR-0011 principle 8, applied to machines.

## Refusal is a first-class outcome

A refusal is written down exactly like a selection, with:

- the route and route version that applied
- every candidate considered
- the exclusion reason for each one
- an explicit refusal reason

**Silence is not an outcome.** An operator asking "why did nothing run?" gets
the same quality of answer as one asking "why did this run there?"

## Local-only refuses rather than degrades

A `local-only` request that cannot run locally is refused. It does not fall
back to a remote instance, however trusted that instance is. The whole point of
the marking is that leaving the host is the thing being prevented.

Which candidate is local is decided by exact identity: the node performing the
selection is supplied to it as `local_node_identity`, and a candidate qualifies
only where its host's `node_identity_reference` equals it. A location class is
not an identity, so `on-premises` never stands in for *local*. When the
identity is missing or unusable the request is **refused** — failing closed,
rather than falling through to a locality nobody asked for.

## A request class with no route is still recorded

No route resolving is an outcome, and it is written down like any other. The
record names no route, because there is none to name: `route_id` and
`route_version` are absent together rather than filled with a placeholder that
would cite a policy that never existed. It stays distinguishable from a route
whose candidates were all excluded — that one names every candidate and its
exclusion reason.

## What the fabric never does when it cannot reach the core

Hosts do **not** continue autonomously. A fabric that keeps operating without
governance has moved the security boundary to wherever the network happened to
partition. Node-local state is a cache, never an authority.

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability routing](capability-routing.md)
- [Capability lifecycle](capability-lifecycle.md)
- [Governance boundaries](governance-boundaries.md)
