# Node Model and Heterogeneous Hardware

**Architecture only.** No node is enrolled, contacted, or represented in any
runtime. Governed by
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md).

A node is a `capability-host` record: the trust subject in the `fabric-node`
domain ADR-0011 reserved.

## What a host record says

| Field | Meaning |
|---|---|
| `node_identity_reference` | Declared by an operator, verified out of band |
| `fabric_node_trust_record_id` | Its standing in the Trust Plane |
| `verified_resource_profile` | What the platform confirmed, not what the host claimed |
| `location_class` | `on-premises`, `operator-controlled-remote`, `third-party-hosted` |
| `data_classification_ceiling` | The highest classification this machine may ever see |
| `availability_intent` | `in-service`, `draining`, `withheld` — set by an operator |

A host record says what the machine **is** and what it may ever **see**. It
never says what it is allowed to **run**: that depends on the package as much as
on the machine, so it lives on the instance.

## Heterogeneous hardware is a controlled vocabulary

Expressed in terms no vendor owns, so a new accelerator generation is a value
rather than a schema change.

| Attribute | Meaning |
|---|---|
| `accelerator_class` | `none`, `integrated-gpu`, `discrete-gpu`, `dedicated-accelerator`, `remote-service` |
| `accelerator_memory_mb` | Usable accelerator memory |
| `accelerator_compute_capability` | Opaque vendor string, compared only by declared match rules |
| `host_memory_mb`, `host_cpu_cores`, `architecture` | The machine itself |

A **package declares its requirements in the same vocabulary**. Matching is
containment: every declared requirement must be satisfied by the host's
**verified** profile.

Matching against the *advertised* profile would be the mistake. It is a
self-report, and the resource profile is precisely the field an attacker would
edit to attract workloads to a machine they control.

`accelerator_compute_capability` is deliberately **opaque**. Ordering vendor
capability strings numerically is the kind of inference that works until the
generation where it does not.

## The concrete machines are records

**No host, GPU, or vendor is named in any schema, ontology entry, or rule.**
The machines this architecture must support are rows in a table, and adding a
fourth requires no code:

| Machine | `accelerator_class` | `location_class` | Notes |
|---|---|---|---|
| **MainPC** — RTX 5070 Ti | `discrete-gpu` | `on-premises` | Large consumer accelerator; high `accelerator_memory_mb` |
| **schai** — Tesla P4 | `discrete-gpu` | `on-premises` | Datacentre accelerator, modest memory; the reference host |
| **schoxmox1** — RTX 4060 | `discrete-gpu` | `on-premises` | Mid-range consumer accelerator on the virtualisation host |
| **A future cloud node** | `remote-service` | `third-party-hosted` | Lower `data_classification_ceiling`; same shape, no special case |

The three GPUs differ in memory and generation, and that difference is carried
entirely by attribute values. A package that needs more accelerator memory than
a host verifiably has simply does not match it — no rule anywhere names a
product.

**Cloud nodes are not a special case.** A third-party-hosted host is a record
with `accelerator_class: remote-service`, a `location_class` that excludes it
from `operator-controlled-only` routes, and a lower classification ceiling.
Nothing in the core changes to admit one.

## Drain and withdrawal

`availability_intent` is how a node is removed from service **deliberately
rather than by failing**. An operator sets it to `draining` or `withheld`;
the fabric stops treating its instances as eligible.

**Nothing sets it automatically.** No health signal, no failure count, and no
timeout drains a node — that would be autonomous remediation, which this
architecture forbids.

## What a node may never do

A host describes itself. It never establishes its own standing.

- It cannot register itself, admit itself, or admit another host.
- It cannot grant, widen, or extend its own scope.
- It cannot create or modify a route.
- It cannot exchange capability, trust, or membership information with another
  host — hosts never see each other.
- It holds **no credential material** in any record: the record proves a
  machine was verified, it is not a way to authenticate as one.

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability identity](capability-identity.md)
- [Governance boundaries](governance-boundaries.md)
- [Trust domains](../trust/trust-domains.md)
