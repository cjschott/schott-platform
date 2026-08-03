# Capability Identity

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md).

Identity is **layered**, and each layer survives changes to the ones below it.
This is the single design choice that makes host migration, hardware
replacement, and package upgrade invisible to consumers.

## Four identities

| Identity | Record | Survives |
|---|---|---|
| **Capability** | `CAPDEF-0000` | contract version changes, package changes, host changes, hardware changes |
| **Contract** | `CCON-0000` | package changes, host changes |
| **Package** | `CPKG-0000` | host changes, hardware changes |
| **Instance** | `CINST-000000` | **nothing** — bound to exactly one host, and dies with it |

The instance is deliberately the fragile one. It is the only record that
encodes "this code, on this machine", so it is the only record that must be
destroyed when either half changes.

## What consumers name

Consumers name a **capability and an accepted contract version range**.

They never name a host, an instance, or a package. A consumer that named a host
would have hardcoded a machine into an architecture whose entire purpose is
that no machine is the platform.

## Host migration

Moving a capability from one machine to another destroys **the instance and
nothing else**.

1. The new host publishes an advertisement.
2. Its resource profile is verified — not copied from the advertisement.
3. An admission decision creates a new instance, referencing the **same**
   `capability_id` and the **same** `capability_package_id`.
4. A new route version lists the new instance.
5. The old instance is superseded and remains readable.

The capability identifier never changed. The consumer never knew. The audit
trail shows exactly when the binding moved and who approved it.

**The old instance is not reused, renamed, or repointed.** Repointing an
instance at a different machine would mean one record described two bindings,
and the question "what was running where in March" would have two answers.

## One capability, many hosts

As **N instances of the same package on N hosts** — nothing more exotic.

Each instance is separately advertised, separately admitted, separately
trusted, and separately eligible. A route lists them in explicit,
human-written order.

There is **no cluster**: no shared state, no leader, no quorum, no replication,
no coordination between hosts, and no awareness among them that the others
exist. Each host knows only what the core routed to it.

Distribution across instances, if it is ever wanted, must arrive as a
**declared, deterministic rule in a route** — never as a load measurement. No
such rule is defined in this release, because nothing executes yet and
inventing a distribution policy for zero traffic would be guessing.

## Node identity

A host's identity is **declared by an operator and verified out of band**.

- A **hostname is a label, not an identity.** Renaming a machine changes
  nothing.
- **Reinstalling a machine makes a new subject**, requiring a new trust
  decision. The identity that was verified no longer exists.
- **No automatic node registration.** A machine that appears on the network and
  announces itself has achieved nothing: an advertisement from an unknown host
  is a claim from an unknown host, and `Unknown` fails closed.

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability lifecycle](capability-lifecycle.md)
- [Node model and heterogeneous hardware](node-model.md)
- [Capability routing](capability-routing.md)
