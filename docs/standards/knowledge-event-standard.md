# Knowledge Event Standard

## Purpose

A knowledge event records that something happened to the platform's understanding of an entity. Evidence records *what was observed*; events record *what the platform did with that observation and when*.

The two are separate because they answer different questions. "What is the branch of REPO-0001?" is an evidence question. "When did we last confirm it, and has anything contradicted it since?" is an event question, and it cannot be answered from a store of facts with no ordering.

Events exist so the platform can reconstruct its own reasoning after the fact. When a drift report turns out to be wrong, the event timeline is what shows whether the platform reasoned badly or was fed a bad observation.

## Scope

Applies to every record written under `events/` in an observation store, and to every producer of such records — currently `tools/observation/orchestrator.py` alone.

Out of scope: evidence content, verification logic, drift rules, and any notion of alerting or delivery. An event is a durable record, not a notification.

## Definition

A knowledge event is an immutable record with a `MEM-` identifier, an `occurred_at` timestamp carrying a timezone, a target, an event type from the approved list, and references to whatever evidence or verification caused it.

Events are **append-only**. There is no update path and no delete path. A mistaken event is corrected by appending a later event, never by editing the earlier one.

## Approved Event Types

Exactly these ten types are approved. A producer that needs an eleventh must amend this standard first — an open-ended vocabulary makes a timeline unreadable, because every consumer must handle types it has never seen.

- `observation-received` — a `CollectorResult` reached the orchestrator and was accepted for processing.
- `evidence-created` — a new immutable evidence record was persisted.
- `evidence-refreshed` — an observation matched existing evidence exactly; freshness was updated and no new record was created.
- `verification-created` — declared intent was compared against evidence.
- `drift-detected` — a verification concluded that observation contradicts declared intent.
- `drift-cleared` — a target previously in drift now matches declared intent.
- `evidence-stale` — supporting evidence aged past its policy maximum.
- `collection-failed` — a collection attempt failed. This describes the collection, never the target.
- `review-required` — a conclusion needs human judgement before it can be trusted.
- `knowledge-state-generated` — a derived state was produced for a target.

## Ordering

Events are sorted by `occurred_at`, then by identifier. The identifier tiebreak matters: two events can legitimately share a timestamp, and without a deterministic secondary sort the timeline would reorder between runs and no two queries would agree.

Ordering is a presentation concern only. **The latest event is not the authoritative declared state.** A timeline is a record of what happened, and the most recent thing that happened may well be `collection-failed`. Consumers that treat the newest event as current truth have reintroduced the mutable-current-state failure mode ADR-0004 rejects.

## Required References

Every event references what caused it, where a cause exists:

| Event type | Must reference |
|---|---|
| `evidence-created`, `evidence-refreshed`, `evidence-stale` | the evidence identifier |
| `verification-created`, `drift-detected`, `drift-cleared` | the verification identifier |
| `collection-failed` | the evidence identifier, when a record was persisted |
| `knowledge-state-generated`, `review-required` | the target |

An event that concludes something without naming its supporting record cannot be audited, and an unauditable conclusion is indistinguishable from a guess.

## Prohibited Content

An event must never contain:

- a secret value, in any field, including explanations and error summaries
- an executable command, script, or remediation instruction
- a field that would cause an action when read

Events are read by tooling. A record that can cause an action when parsed is a remote-execution surface with extra steps.

## Compliance

A producer complies with this standard when:

- every event carries a six-digit `MEM-` identifier allocated by the orchestrator
- every `occurred_at` timestamp is ISO 8601 with an explicit offset
- every event type appears in the approved list above
- events are written once and never modified or deleted
- every event references its originating evidence or verification where the table above requires it
- query results are sorted by `occurred_at` then identifier
- no event contains a secret, a command, or a remediation instruction

Enforced by `tests/test-knowledge-orchestrator.sh` and asserted structurally by `tests/test-docs-static.sh`.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Confidence and Freshness Standard](confidence-freshness-standard.md)
- [Evidence Standard](evidence-standard.md)
