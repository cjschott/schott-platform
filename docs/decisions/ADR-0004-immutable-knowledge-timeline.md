# ADR-0004: Immutable Knowledge Timeline

- **Status:** Accepted
- **Date:** 2026-08-01
- **Decision Makers:** Schott Platform Engineering

## Context

ADR-0002 established that the platform is evidence-first: a claim about the platform is only as good as the observation supporting it. v0.5.0 built the collector framework and v0.6.0 built three real collectors. Neither persisted anything.

That was deliberate — a collector that numbers and stores its own records controls the audit trail — but it leaves the platform unable to answer the question that matters most in operations: *what did we know, and when did we know it?*

Answering that requires memory, and memory is where evidence systems usually go wrong. The failure mode is well-known and seductive: keep a `current-state.yaml` per entity, overwrite it on every collection, and read it when someone asks. It is simple, it is fast, and it destroys the only thing that made the evidence trustworthy. Once a record is overwritten, nobody can distinguish "this was always true" from "this changed and we lost the previous answer". Drift becomes undetectable precisely when it matters, because the evidence of the previous state is gone.

There is a second failure mode that is quieter. A system that observes the platform and then edits the declared model to match what it saw has stopped verifying anything. It has redefined correctness as "whatever is currently running", which is the opposite of what a platform model is for. Divergence between intent and reality is the signal; silently erasing it discards the signal and reports success.

## Decision

The platform records observations as an **immutable, append-only timeline**, and derives current knowledge from that timeline rather than storing it.

The pipeline is explicit, and each stage has exactly one responsibility:

```
CollectorResult
    ->
Observation
    ->
Immutable Evidence
    ->
Verification
    ->
Drift Assessment
    ->
Knowledge Event
    ->
Derived Knowledge State
```

A `CollectorResult` is what a plugin returns. An `Observation` is that result validated, redacted, and normalized. **Evidence** is an observation that has been given a persistent identifier and written once. **Verification** compares evidence against declared intent. **Drift Assessment** classifies the difference. A **Knowledge Event** records that something happened. **Knowledge State** is derived on demand and never stored as truth.

### Principles

1. **Collectors return observations only.** They have no identifier field, no store handle, and no write path.
2. **The orchestrator assigns persistent identifiers.** `EVID`, `VER`, and `MEM` sequences are allocated in one place, outside plugin code.
3. **Evidence is immutable and append-only.** There is no update method and no delete method.
4. **Recollection never overwrites evidence.** Observing the same thing again produces a new record or a refresh event, never an edit.
5. **Duplicate content may refresh knowledge without duplicating evidence.** Identical normalized content updates freshness; it does not create a second record of the same fact.
6. **Timelines are append-only.** Events are never rewritten or removed.
7. **Knowledge state is derived and reproducible.** The same inputs always produce the same state.
8. **Declared intent is not silently rewritten.** No code path in this increment modifies a canonical entity.
9. **Observed facts do not automatically become declared facts.** Promoting an observation to intent is a human decision.
10. **Missing evidence is not drift.** Never having looked is not the same as having looked and found a difference.
11. **Collection failure is not service failure.** A collector that could not look has learned nothing about the target's health.
12. **Staleness lowers confidence but does not prove failure.** Old evidence is weak evidence, not contrary evidence.
13. **Recommendations remain advisory.** Every recommended action is prose for a human to read.
14. **Remediation requires explicit human approval.** No automatic action exists anywhere in this layer.
15. **Every conclusion must reference supporting evidence.** A verification or drift result that names no evidence identifier is not a conclusion; it is an opinion.
16. **Knowledge can be rebuilt from evidence and events.** Derived state is disposable by design.

### What this decision does not authorize

It does not authorize remote collection, a database, a network service, an HTTP API, or LLM-based reasoning. Those are separate decisions with separate risk profiles, and none of them is required to make the timeline work.

## Rejected Alternatives

**Mutable current-state files.** One file per entity, overwritten on each collection. Simple and fast, and it destroys history exactly when history is the thing being asked for. Drift becomes undetectable because the previous state is gone.

**Collectors writing evidence directly.** Removes a layer and removes the boundary with it. A collector that can write to the evidence store can rewrite its own history, and the audit trail becomes only as trustworthy as the least careful plugin.

**Updating old evidence in place.** Appealing for correcting a mistaken observation. It means a record's content can change after anyone has cited it, so a verification referencing `EVID-000042` no longer describes what `EVID-000042` currently says. Corrections supersede; they do not edit.

**Treating duplicate observations as new evidence.** Honest but unusable: a collector on a five-minute schedule produces hundreds of identical records a day, and the signal drowns. Identical content refreshes freshness instead.

**Treating stale evidence as drift.** Conflates "we have not looked recently" with "reality has diverged". It generates false drift on every collection outage and trains operators to ignore drift reports.

**Automatically updating canonical entities to match observation.** Ends verification entirely. If the model always matches reality, it can never disagree with reality, and the platform has an expensive way to describe its own current state rather than a way to check it.

**Database-first architecture in this sprint.** A graph or relational store is a plausible eventual home for this data. Adopting one now would add an operational dependency, a backup surface, and a migration path before the data model has been exercised against real input even once. Files on disk are inspectable with `cat`, diffable, and trivially backed up. The database decision stays open.

## Consequences

**Positive.** History is preserved by construction rather than by discipline. Any knowledge state can be rebuilt from immutable inputs, so a bug in derivation is a bug in code rather than corrupted data. Evidence records are plain YAML, readable without tooling. The declared model stays authoritative because nothing can rewrite it.

**Negative.** Storage grows monotonically; pruning will eventually need a retention decision, and that decision is deliberately deferred. Derivation costs more than reading a cached answer. Six-digit identifiers make records slightly less pleasant to read than four-digit ones.

**Accepted risks.** Sequence allocation is safe for one local host and would need rework for multi-host collection. Confidence scoring is an explainable heuristic rather than a statistical probability, and the standard says so plainly so no consumer mistakes it for one.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [Evidence Standard](../standards/evidence-standard.md)
- [Verification and Drift Standard](../standards/verification-drift-standard.md)
- [Knowledge Event Standard](../standards/knowledge-event-standard.md)
- [Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
