# ADR-0002: Evidence-First Architecture

- **Status:** Accepted
- **Date:** 2026-08-01
- **Decision Makers:** Schott Platform Engineering

## Context

The platform model records **declared intent**: what the platform is supposed to be. Verification needs a second kind of knowledge — what it actually was, at a moment, according to something that looked.

Joining those two kinds of knowledge is where operational models usually go wrong, for four reasons:

- **The declared model represents intended state.** It is reviewed, versioned, and authoritative about intent. It is not a measurement.
- **Runtime observations may be incomplete, stale, contradictory, or unavailable.** A collector that cannot reach a host has learned nothing, which is a different fact from learning that the host is broken.
- **Directly updating canonical entities from collectors destroys traceability.** If an observation overwrites a declaration, the reviewed intent is gone and no one can later ask what was intended or who changed it.
- **Automated remediation based on unverified collection is unsafe.** A collector that acts on what it finds will eventually act on something it misread, and the blast radius is production.

The tempting shortcut — let collectors write the model — is precisely the thing that makes the model untrustworthy.

## Decision

All runtime knowledge flows through a fixed pipeline. Every stage is separate, and no stage may skip forward.

```text
Runtime
    ->
Collector
    ->
Normalized observation
    ->
Evidence record
    ->
Verification
    ->
Drift assessment
    ->
Recommendation
    ->
Human approval
    ->
Optional automation
```

Each arrow is a boundary where the data changes trust class, and where a component with narrow permissions hands off to another with different ones. The collector at the front has the least authority in the system, deliberately, because it is the part touching the outside world.

## Required Principles

1. **Collectors never modify canonical entities.** They return data; something else decides what becomes a record.
2. **Evidence is immutable.** A record describes one moment; editing it destroys the only thing it was for.
3. **Recollection creates new evidence.** Two collections are two facts about two moments, not one fact updated.
4. **Verification is deterministic where possible.** The same evidence and rules should produce the same finding.
5. **Drift is advisory.** A finding is input to a decision, not a decision.
6. **Missing evidence is not drift.** "We did not look" and "we looked and it differs" are different facts, and conflating them manufactures findings that erode trust in the whole layer.
7. **Collection failure is not service failure.** A failed connection means the platform could not observe, not that the target is down.
8. **Automation is opt-in.** Nothing becomes automated by accumulating enough successful verifications.
9. **High-impact action requires approval.** Severity does not grant authority.
10. **Every conclusion must be explainable through evidence references.** A finding whose supporting evidence cannot be named is unfalsifiable, and an unfalsifiable finding is not a finding.
11. **Declared intent remains authoritative until reviewed.** Observation informs; it does not legislate.
12. **Observed state never silently replaces declared intent.** When the two disagree, that disagreement is reported as drift — the point at which a human decides which side is wrong.

## Consequences

### Positive

- **Stronger auditability.** Every conclusion traces back through verification, to evidence, to a collector, to a moment in time.
- **Safer future automation.** Automation consumes reviewed findings rather than raw observation, so a bad collection cannot become a bad action without passing a human.
- **Clear separation between fact collection and policy decisions.** Collectors answer "what did you see"; rules answer "does that matter"; humans answer "what should we do".

### Trade-offs

- **More records and more processing stages.** A single fact becomes an observation, an evidence record, and a verification result. This is a real storage and complexity cost accepted deliberately.
- **Temporary coexistence of declared and contradictory observed facts.** The model will sometimes hold a declaration and an observation that disagree, and will report both rather than resolving them. That is the honest state, but it means consumers must handle disagreement rather than assuming a single truth.

## Rejected Alternatives

- **Collectors directly editing entity YAML.** Simplest to build, and destroys traceability immediately. Reviewed intent would be silently overwritten by whatever the last collection saw.
- **Automatically accepting observed state as truth.** Makes the model self-consistent by definition and useless for detecting misconfiguration: if reality always wins, drift can never be reported.
- **Automatic remediation during collection.** Merges the least-trusted component with the highest-impact action. A misread becomes a production change with no review in between.
- **Storing only the latest observation.** Discards the history that makes drift interpretable. Without the previous observation there is no way to tell a new problem from a long-standing one.
- **Treating unavailable evidence as healthy or failed.** Either choice invents information. Unavailable means the platform does not know, and the model must be able to say so.

## Relationship to Other Standards

- [Evidence Standard](../standards/evidence-standard.md) defines the evidence record this pipeline produces.
- [Verification and Drift Standard](../standards/verification-drift-standard.md) defines the comparison stage.
- [Collector Plugin Standard](../standards/collector-plugin-standard.md) defines the contract collectors implement.
- [Entity Lifecycle Standard](../standards/entity-lifecycle-standard.md) defines why verification never rewrites entity maturity automatically.
