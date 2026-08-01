# Definition of Done Standard

## Purpose

This standard defines when a unit of Schott Platform work is actually finished.

"Done" is not "the code runs." Work is done when the platform can be operated, recovered, and understood by someone who was not present when it was built. Most operational debt enters a platform through work that was merged while still technically functional but undocumented, unmonitored, or unrecoverable.

This standard makes those obligations explicit and checkable, so the decision to defer one is a recorded choice rather than an oversight.

## Scope

This standard applies to platform changes: services, hosts, automation, standards, model records, and infrastructure configuration.

It does not apply to trivial corrections such as typo fixes, comment wording, or formatting, which may be merged on reviewer judgment alone.

## Core Principle

Each gate below applies **when applicable** to the change at hand.

Applicability is a judgment the author makes and the reviewer confirms. A gate that does not apply must be stated as not applicable with a one-line reason. Silence is not a valid answer — an unmentioned gate is treated as unmet.

Deferring an applicable gate is permitted when the deferral is recorded with an owner and a follow-up reference. Deferring it silently is not.

## Gates

### Architecture alignment

The change fits the approved architecture and does not quietly redesign it.

- It respects existing service boundaries and stable interfaces.
- It does not introduce an undocumented dependency.
- It does not contradict an accepted architecture decision.
- If it changes architecture, an architecture decision record accompanies it.

### Tests

The change is covered by executable verification appropriate to its kind.

- New behavior has tests written before or alongside it.
- Bug fixes include a test that reproduces the defect.
- Documentation and model changes have static assertions.
- The full local suite passes, and no existing assertion was weakened to achieve it.
- Test results are reported honestly, including skips and their reasons.

### Documentation

A reader who was not involved can understand and use the change.

- Affected operational documents are updated in the same change.
- New configuration, commands, and endpoints are documented.
- Removed behavior is removed from the documentation too.
- Documentation states what is *not* covered where that is material.

### Service catalog

Service records reflect reality.

- New long-lived services have a catalog record before production use.
- Changed ownership, exposure, dependencies, or criticality are recorded.
- Retired services are marked, not deleted.

### Platform model

The machine-readable model stays consistent with the change.

- New hosts, services, networks, storage, and policies have entities.
- Relationships are declared once in the canonical edge list.
- Facts carry a provenance class; unverified facts are flagged for review rather than guessed.
- No volatile runtime value is recorded as a declared fact.

### Runbook

An operator can run and recover the thing without the author.

- Start, stop, restart, and validation procedures exist.
- Failure modes and their first diagnostic steps are documented.
- Recovery steps are written down and, where practical, tested.

### Observability

Failure is detectable without a user reporting it.

- The authoritative log source and its retrieval command are recorded.
- A health check exists and is documented.
- Metrics, dashboards, and alerts are updated where the platform supports them.
- Gaps in coverage are stated explicitly rather than implied.

### Security review

The change does not widen exposure without a decision.

- Exposure classification is confirmed or updated.
- Authentication and authorization behavior is stated, including failure-closed behavior.
- No secret is committed; secret sources are referenced by path only.
- Firewall and access implications are documented for manual operator application.
- Scanner findings are resolved or explicitly accepted with a reason.

### Performance

Resource cost is considered before it becomes an incident.

- CPU, memory, GPU, disk, and network impact are considered proportionate to the change.
- Obvious inefficiencies are addressed or recorded.
- Latency-sensitive paths are measured rather than assumed.
- Known performance limitations are documented.

### Backup and recovery

Data survives the loss of the thing holding it.

- Authoritative versus reconstructable data is identified.
- Backup scope and destination are recorded, or the absence is justified.
- Restore procedure and dependency ordering are documented.
- Tier 0 and Tier 1 work carries backup coverage or a recorded exception.

### Release notes

The change is discoverable by someone reading history.

- User-visible changes are summarized.
- Breaking changes are called out explicitly.
- Known limitations and deferred work are listed.

### Evidence integrity

Work that produces or consumes evidence preserves the ADR-0004 guarantees.

- Evidence is written once; no change adds an update or delete path.
- Identifiers are allocated by the orchestrator, never by a collector.
- Generated records stay out of `platform-model/`.
- Missing evidence is reported as absence of observation, never as drift.
- Collection failure is reported as collection failure, never as target failure.
- Stale evidence lowers confidence and does not support a verified state.
- Every conclusion names the evidence identifiers supporting it.
- No secret reaches a record, an index, a fingerprint, or an error message.

### Reviewer approval

A second person has agreed the work is complete.

- Every applicable gate is satisfied, deferred with an owner, or marked not applicable with a reason.
- Required checks are green.
- Testing evidence is provided and accurate.
- The reviewer confirms scope matches what was requested.

## Reporting Format

Work submitted for review should state gate status directly, for example:

```text
Architecture alignment : met
Tests                  : met - 174 model assertions, red phase captured
Documentation          : met
Service catalog        : not applicable - no service added
Platform model         : met - 3 entities, 6 relationships
Runbook                : deferred - owner: platform-engineering, follow-up: v0.4.0
Observability          : not applicable - no runtime component
Security review        : met - no secrets, scanners green
Performance            : not applicable - documentation only
Backup and recovery    : not applicable - no persistent data
Release notes          : met
Reviewer approval      : pending
```

## Compliance

Work complies with this standard when:

- Every gate is addressed as met, deferred with an owner and follow-up, or not applicable with a reason.
- No applicable gate is silently skipped.
- Test results, including skips and limitations, are reported accurately.
- Deferred obligations are tracked rather than forgotten.
- A reviewer has confirmed completion.
