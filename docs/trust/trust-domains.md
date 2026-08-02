# Trust Domains

Fifteen domains, each with its own **trust boundary**: the line across which a
subject's assertions stop being taken at face value.

> **Architecture only. Not yet implemented.** No runtime governs these domains
> in this release. Reserved for **v0.9.2**.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md). See also
[the Trust Plane overview](trust-plane.md) and [trust states](trust-states.md).

## Domains do not inherit

**A subject in one domain is never automatically a subject in another.**

Trusting a host does not trust the SSH host key that identifies it. Trusting a
model does not trust the prompt bundle used with it. Trusting a capability
package does not trust the node that offers it.

Inheritance is convenient and it means a single decision has consequences nobody
enumerated. Each domain is entered explicitly.

## The fifteen domains

### Host Trust

**Subject:** a machine the platform may observe or use.
**Identifier:** the declared DNS name or explicit address literal.
**Boundary:** the platform accepts a host's *reported facts* as observations of
what it claims about itself. It never accepts a host's claim about its own
identity, its own trustworthiness, or another subject's.
**Note:** a host can lie. Everything collected is what the machine says about
itself, and being read-only does not change that.

### SSH Host Keys

**Subject:** one host key for one host identity.
**Boundary:** verification is mandatory and cannot be disabled. Unknown and
changed keys fail closed.
**Forbidden:** automatic `ssh-keyscan`, automatic `known_hosts` updates,
trust on first use. Reading a key from the connection being verified proves
nothing about it.
**Note:** OpenSSH keys entries by the host string as given, so a name and its
address are *separate subjects*, as are the same host on different ports.

### Certificates

**Subject:** an X.509 or comparable certificate.
**Boundary:** validity is checked; a valid signature establishes the chain, not
the appropriateness of the subject.
**Forbidden:** automatic acceptance. Expiry, rotation, and reissue are decisions.

### Users

**Subject:** a human or service identity acting on the platform.
**Boundary:** an identity is trusted to *act within a scope*, never to expand its
own scope. An authority may not approve itself.

### Collector Plugins

**Subject:** one plugin at one version.
**Boundary:** a plugin's manifest is a *declaration to be checked*, not a
statement to be believed. A manifest claiming no network access does not make it
so; the framework enforces the boundary independently.
**Note:** this domain already has a working precursor — the explicit plugin
registry, where a plugin appearing on disk is a plugin nobody reviewed.

### Capability Packages

**Subject:** a unit of capability offered to the platform.
**Boundary:** trusted by review of its contents, never by successful
installation or by running without incident.
**Forbidden:** automatic capability approval.

### Models

**Subject:** one model at one version.
**Boundary:** model *output* is never trust evidence. A model may consume trust
records; it may never produce, raise, or restore one.
**Forbidden:** automatic model approval — **a new model version is a new
subject**, because behaviour is not carried across versions.

### Model Adapters

**Subject:** the adapter mapping a provider to the platform's gateway contract.
**Boundary:** an adapter is trusted to *translate*, never to choose a provider,
add a fallback, or widen what a model may see. Separate from the model itself
because an adapter can change what reaches a model without the model changing.

### Prompt Bundles

**Subject:** a versioned set of prompts.
**Boundary:** a prompt bundle is *input to reasoning*, and reasoning cannot
establish trust — so a bundle can never authorise anything, however it is
worded. Trusted separately from the model because the same model with a
different bundle is a different system.

### Embedding Models

**Subject:** one embedding model at one version.
**Boundary:** embeddings are trusted as a *representation*, never as a judgement.
Held separately from generative models because changing one silently invalidates
every index built with it.

### Indexes

**Subject:** a built index over a corpus.
**Boundary:** an index is trusted to reflect the corpus *at the time it was
built*, and carries the identity of the embedding model that built it. An index
whose embedding model is no longer trusted is not itself trusted.

### Policies

**Subject:** a trust policy or operational policy.
**Boundary:** a policy governs subjects; it never governs itself.
**Forbidden:** automatic policy changes. A policy that can rewrite itself is not
a policy.

### Configuration Snapshots

**Subject:** a captured configuration state.
**Boundary:** a snapshot is trusted as an accurate *record of what was
configured*, never as a statement that the configuration was correct.

### Remote Transports

**Subject:** a transport implementation and its pinned options.
**Boundary:** a transport is trusted to *carry* an operation, never to choose
one. Held separately from the host because the same host reached by a different
transport is a different risk.
**Note:** the existing SSH transport is a precursor — one audited chokepoint,
fixed executable, pinned options, code-owned argv.

### Fabric Nodes

**Subject:** a machine offering capacity to the platform (v0.9.5 and later).
**Boundary:** **a node's self-report is not trust.** A node describes its own
capabilities, resources, and health; the Trust Plane decides whether that
description is believed and what the node may see.
**Note:** this domain is why the Fabric is gated on the Trust Plane.

## Existing mechanisms this will eventually absorb

The platform already makes trust decisions in four places. **All keep working
unchanged in this release**; migration is deliberately deferred.

| Existing mechanism | Domain it foreshadows |
|---|---|
| `known_hosts` references in remote targets | SSH Host Keys |
| The explicit collector plugin registry | Collector Plugins |
| The code-owned remote operation catalog | Remote Transports |
| A target's `allowed_operation_ids` | Host Trust, scoped |

Each already embodies the right instinct — explicit, reviewed, fail-closed — in
its own format, with its own lifetime, and with no shared way to answer who
decided, on what evidence, for how long, and how it is withdrawn.

## Related

- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [The Trust Plane](trust-plane.md)
- [Trust states](trust-states.md)
