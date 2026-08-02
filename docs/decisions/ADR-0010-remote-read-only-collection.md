# ADR-0010: Remote Read-Only Collection

- **Status:** Accepted
- **Date:** 2026-08-02
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved.

## Context

Every release through v0.8.6 was local by construction. The platform observes this repository, renders Compose configuration, and accepts human attestation — and it describes ten hosts it has never contacted. The model is honest about that, but it is a model of a platform rather than a model of the platform.

Closing that gap requires reaching other machines, which is the largest single expansion of blast radius this platform has taken. Everything before it could, at worst, produce a wrong record. This can, at worst, run something somewhere else.

The temptation is a general SSH collector: hand it a hostname and a command string, let configuration decide what runs. It would be finished in an afternoon, cover every future need, and require no further work when a new fact is wanted.

It is also a remote execution service with an observability label on it. Once command text lives in configuration, anyone who can edit configuration can run anything the collector's credentials permit — and configuration is reviewed as data, not as code. The same reasoning applies to each of its smaller cousins: `sudo` "just for this one file", `StrictHostKeyChecking=no` "because the key changed after the rebuild", a password field "for the one host without keys". Each is locally reasonable. Together they are an administration channel.

## Decision

The platform gains **remote read-only collectors** bound by one distinction:

> **Remote collectors observe. They never administer.**

### The contract change

v0.5.0 required `network_access: false` for every plugin. That is now **narrowed**, not relaxed, exactly as v0.6.0 narrowed the subprocess prohibition:

| v0.5.0 | v0.9.0 |
|---|---|
| No plugin may declare network access | Network permitted **only** with the `read-remote-host` permission |
| Enforced by absence of the capability | Enforced by an audited transport plus a code-owned catalog |

A plugin still never opens a socket and never composes a command. It names an operation identifier; the catalog owns the argv.

### Principles

1. **Remote collectors observe; they never administer.**
2. **Targets are declared explicitly.** One machine per target, as a DNS name
   or an explicit IPv4 or IPv6 literal. No discovery, no CIDR, no defaults.
3. **Every executable operation comes from a code-owned allowlist.**
4. **Configuration may choose an operation identifier, never supply command text.**
5. **Host-key verification is mandatory** and cannot be disabled.
6. **Unknown host keys fail closed.**
7. **Authentication material is referenced, never stored** in collector records.
8. **Remote output is bounded by time and bytes.**
9. **A collection failure is not target failure.**
10. **Partial output is not accepted** after timeout or truncation.
11. **Remote collectors return `CollectorResult` only.**
12. **Collectors never persist evidence.**
13. **Secrets are redacted before normalization and fingerprinting.**
14. **No remote state is changed.**
15. **Every remote operation is auditable** — the identifier and argv are in the repository, not in configuration.
16. **The control plane keeps operating if every remote target is unavailable.**

### What a target may be

*Amended during review of the v0.9.0 implementation.*

The first implementation required a DNS name, refusing address ranges and bare
address literals with a single rule. That was too broad. Requiring a name means
the platform cannot observe a host precisely when name resolution is what
broke — and bootstrap and DNS failure are exactly the situations an address
literal exists for.

A target is therefore **one machine**, expressed as a DNS name, an IPv4
literal, or an IPv6 literal. Everything expressing a *scope* rather than a host
stays refused: CIDR ranges, address ranges, wildcards, lists, URLs, embedded
usernames, and host:port syntax. Malformed literals are refused rather than
quietly accepted as names, and address literals are parsed by a real address
parser rather than matched by a pattern.

**Naming one machine by address is not host discovery.** The platform is told
about one machine; nothing resolves a name, reverses an address, or expands a
scope. Host-key verification is unchanged for address literals — an IP target
is verified exactly like a name.

### Why collection is atomic at the collector level

If any required operation fails, the collector returns nothing: no facts, no
fingerprint, and successful intermediate output is discarded rather than
reported.

The alternative — returning what did arrive — produces a record that reads as
complete while silently missing fields, and every layer above treats a
successful record as a full one. A clean failure with a specific category is
more useful to an operator than a partial record that has to be second-guessed.

The cost is real: one failing operation loses facts that were successfully
collected. Partial collection with an explicit completeness marker is a
reasonable future design, and is deliberately deferred rather than approximated
here.

### Why connection failure is not host failure

A collector that cannot connect has learned nothing about the target. The host may be fine and the network broken; the credential may have expired; DNS may be wrong. Reporting `transport_failure` as "host is down" manufactures an outage out of an observation gap, and the platform already has a layer whose job is interpreting evidence.

Failure categories — `authentication_failure`, `host_key_failure`, `timeout`, `output_limit`, `transport_failure`, `unsupported_target`, `collection_failure` — all describe **the collection attempt**. None claims the host is down, a service failed, or declared state is wrong.

### Why there is no sudo

Every fact these collectors gather is readable unprivileged. Adding `sudo` would buy nothing here and would mean the platform holds privileged remote execution for the day someone wants a fact that needs it — at which point the decision would already have been made, quietly, by a collector.

### Why service enumeration is restricted

`systemctl show <unit>` against units named in the target's allowlist is bounded and auditable. Enumerating every unit returns an unbounded list shaped by whatever is installed, and turns a targeted question into a survey. Broad enumeration can be authorized later, as a decision rather than a default.

## Rejected Alternatives

**An arbitrary SSH command collector.** Solves every present and future need in one component, and is a remote execution service wearing an observability label. Once command text is configuration, anyone who can edit configuration can run anything the credential permits.

**Shell text supplied in YAML.** The same failure with an extra step. Configuration is reviewed as data; command text is code.

**Disabling host-key checking.** Makes first contact and post-rebuild reconnection painless, and removes the only defence against a machine-in-the-middle. A collector that trusts any key trusts an attacker's key.

**Accepting changed host keys automatically.** A changed key is exactly the event the check exists to surface. Auto-accepting converts the alarm into a log line nobody reads.

**Embedding private keys in repository configuration.** Convenient and irreversible: a key in git history is a key that must be rotated, and every clone is a copy.

**Remote sudo.** Not needed for anything collected here, and it would make the platform a privileged remote execution channel by default.

**Package installation on targets.** Would make collectors administer hosts, which is the distinction this ADR exists to hold.

**General-purpose Ansible execution in this sprint.** Ansible is a fine tool for change management, and change management is not observation. Adopting it here would blur the boundary at the moment it most needs to be sharp.

**Collector-owned evidence persistence.** ADR-0004 settled this: a collector that numbers and stores its own records controls the audit trail.

**Treating connection failure as host outage.** Produces false outages on every network hiccup and trains operators to ignore them.

## Consequences

**Positive.** The platform can finally observe the hosts it describes. The blast radius is bounded by a nine-operation catalog that lives in reviewed code. Every remote operation is auditable by reading the repository rather than by reconstructing what configuration asked for.

**Negative.** Adding a fact now requires a code change and review rather than a configuration edit — deliberate friction, and it will feel slow the first time someone wants a new field. Host keys must be enrolled outside collection. The platform now depends on the OpenSSH client's behaviour.

**Accepted risks.**

- **The transport is only as safe as its argv.** Every relevant option is pinned explicitly rather than inherited from ambient configuration, and static tests assert the forbidden ones are absent — but the client is external code.
- **Fake-transport coverage is not real-world coverage.** No test here proves the client behaves as modelled against a live host; first real use needs supervised validation.
- **Credentials exist somewhere.** This ADR keeps them out of the repository and out of records; it does not solve secret management, which remains an operator responsibility.

## Relationship to the Distributed Capability Fabric

v0.9.5 will let the platform *use* other machines. This release only lets it *look at* them, and the ordering is deliberate: observation before placement, so the fabric is built on a platform that can already describe the nodes it would place work on.

The rule extends: **no model is Kyri, and no machine is Kyri.** A target here is a thing observed, never a thing the platform depends on to function — principle 16 exists so that remains true.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [ADR-0003: Provider-Agnostic AI Architecture](ADR-0003-provider-agnostic-ai-architecture.md)
- [ADR-0004: Immutable Knowledge Timeline](ADR-0004-immutable-knowledge-timeline.md)
- [Remote collection overview](../collectors/remote-collection.md)
- [Collector Plugin Standard](../standards/collector-plugin-standard.md)
