# ADR-0007: Operational Integrity Engine

- **Status:** Accepted
- **Date:** 2026-08-02
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** This record is ADR-0007. ADR-0005 and ADR-0006 are
> unassigned and reserved; the gap is deliberate, not an omission.

## Context

ADR-0004 gave the platform memory: immutable evidence, an append-only timeline,
and a knowledge state derived on demand. The platform can now answer *what do we
believe about this target, and why*.

It cannot answer the question an operator asks during an incident: **is this
still the system we think it is?**

Answering that needs a reference point — a state someone confirmed was good —
and a way to reconstruct the current state and compare the two. Neither exists
today. Knowledge state describes *now*; nothing describes *then*, and nothing
compares them.

There are two well-worn ways to get this wrong.

The first is to keep a mutable "expected state" file and edit it whenever
reality changes. It always converges on describing whatever is currently
running, at which point it can never disagree with reality and the comparison
becomes decorative.

The second is to let the comparison act. A system that detects a difference and
corrects it is enormously appealing during an incident and catastrophic outside
one: the moment a wrong conclusion can execute, a bad inference stops being a
bad suggestion and becomes an outage. Worse, drift is frequently *intended* —
someone deployed something — and an engine that reverts intended change is
itself the incident.

## Decision

The platform gains an **Operational Integrity Engine** built on four concepts,
and it recommends without ever acting.

```
Reality → Observation → Evidence → Verification → Knowledge
        → Snapshot → Digital Twin → Integrity Analysis
        → Recovery Recommendation → Human Approval
```

Automation sits outside this pipeline entirely. The chain ends at a human.

### Snapshot

An immutable representation of a known-good operational state.

Written once and never revised. A newer snapshot of the same target is a new
record; the earlier one stays readable, because a reference point that can
change after something cited it is not a reference point. Snapshots are
versioned, fingerprinted, and deterministic — the same knowledge reproduces a
byte-identical record, which is what makes one verifiable rather than merely
stored.

A snapshot records what was **observed** at a moment a human labelled good. It
is not a statement of what the platform *should* be. That distinction is what
keeps it evidence rather than intent.

### Digital Twin

A mutable working representation reconstructed entirely from current knowledge.

Twins are **disposable by design**. They are rebuilt from immutable inputs every
time and never edited directly, so a reconstruction bug is a bug in code that a
rerun fixes rather than corrupted state to repair by hand. This is ADR-0004's
derived-state reasoning applied one layer up.

A twin that could be hand-edited would be a guess wearing a reconstruction's
name, so the type is frozen and its facts are write-protected.

### Integrity Report

The comparison between a twin and a snapshot, classified as one of five states:

| Status | Meaning |
|---|---|
| `MATCH` | every comparable fact agrees |
| `PARTIAL` | some agree, some differ |
| `DRIFT` | every comparable fact differs |
| `UNKNOWN` | nothing could be compared |
| `INSUFFICIENT_EVIDENCE` | the twin holds no facts at all |

The last two carry most of the weight. Reporting "we could not tell" as `DRIFT`
produces a false alarm on every gap in coverage, and an operator paged three
times for a coverage gap stops reading drift reports — which costs more than the
alarm was ever worth. Keeping them separate is what makes a `DRIFT` report worth
acting on.

Every report carries a confidence score with its factors, weights,
contributions, and a written reason per factor. There are no opaque confidence
values in this engine.

### Recovery Plan

A human-readable reconstruction strategy. **Recovery is advisory only, and this
engine never executes it.**

Every step is prose. There is deliberately no command field, no script, no
ordering primitive an executor could consume, and no `execute` method. That is
not a gap to be closed in a later increment — it is the decision. A plan
explicitly directs reconstruction through the platform's normal change process,
with its usual review and rollback, and states that the engine performs no part
of one.

### Principles

1. Snapshots are immutable and never revised.
2. Twins are disposable and rebuilt from knowledge alone.
3. A twin is never edited directly.
4. Comparison is deterministic and read-only.
5. Missing evidence is `INSUFFICIENT_EVIDENCE`, never drift.
6. An uncomparable fact is `UNKNOWN`, never drift.
7. Every score explains itself.
8. A snapshot records observation, not intent.
9. Detected drift may be intended change; the engine cannot tell which.
10. Recovery is recommended, never performed.
11. Every conclusion names the snapshot and twin it came from.
12. Nothing here modifies the declared model.

## Rejected Alternatives

**A mutable expected-state file.** Edited whenever reality changes, it converges
on describing whatever is running. Once it always matches reality it can never
disagree with reality, and the comparison stops meaning anything.

**Automatic recovery on detected drift.** The feature everyone asks for. Drift is
often intended change, and an engine that reverts a deployment because it did not
recognise it has caused the incident it was meant to prevent. Acting requires a
human who can tell the difference.

**Machine-readable recovery steps.** A structured action list looks harmless and
is one scheduler away from execution. Keeping steps as prose means adding
automation later is a deliberate, reviewable decision rather than wiring
something that already exists.

**Snapshotting raw collector output.** Cheaper, and it would embed unredacted
source material in an immutable record that by design can never be edited.
Snapshots are built from knowledge, which is already normalized and redacted.

**Treating any difference as drift.** Simple and produces false alarms on every
coverage gap, training operators to ignore the reports.

**Storing twins alongside snapshots.** A persisted twin is indistinguishable from
a snapshot at a glance, and the difference between "confirmed good" and
"reconstructed just now" is the entire point. Twins are returned, not stored.

**Extending the evidence store with new record kinds.** Would have avoided a
second write path, and would have changed the orchestration layer this increment
is meant to leave alone. Duplicating a small, well-understood write path is the
cheaper risk; consolidating it later is a contained refactor.

## Consequences

**Positive.** The platform can answer "is this still the system we think it is?"
with a cited, explainable answer. Snapshots are immutable, so a comparison made
today remains reproducible tomorrow. Nothing can act on a wrong conclusion,
because nothing can act at all.

**Negative.** Snapshot storage grows monotonically; retention is deliberately
deferred, as it is for evidence. A snapshot's usefulness decays as intended
change accumulates, so someone must take new ones — the engine cannot decide when
a state is good. There are now two immutable write paths in the codebase.

**Accepted risks.** A stale snapshot produces noisy `PARTIAL` reports that could
train operators to dismiss them; the plan text addresses this by asking whether
the snapshot is still an appropriate reference before anything else. Confidence
is an explainable heuristic, not a calibrated probability, and says so in its own
output.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [ADR-0004: Immutable Knowledge Timeline](ADR-0004-immutable-knowledge-timeline.md)
- [Operational integrity overview](../integrity/overview.md)
- [Verification and Drift Standard](../standards/verification-drift-standard.md)
