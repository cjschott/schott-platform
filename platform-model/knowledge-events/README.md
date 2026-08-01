# Knowledge Events

This directory holds the **schema-governed definition** of what a knowledge
event is. It does not hold events.

An event records that something happened to the platform's understanding of an
entity. Evidence records *what was observed*; an event records *what the
platform did with that observation, and when* — see
[`../schemas/knowledge-event.schema.yaml`](../schemas/knowledge-event.schema.yaml)
and the [Knowledge Event Standard](../../docs/standards/knowledge-event-standard.md).

## Nothing generated is committed here

Runtime events live in an observation store outside the repository, under
`events/` in a data root supplied explicitly to `tools/observation/cli.py`.

Events are the highest-volume record the platform produces — several per
ingestion, and ingestion happens on a schedule. Committing them would bury the
declared model under machine output and make every review a search problem.

The append-only guarantee lives in the store, which refuses to overwrite an
existing record. It is not something version control provides here, and
committing events would create a second, editable copy of a record whose whole
value is that it cannot be edited.

`tests/test-knowledge-orchestrator.sh` asserts that no `MEM-` record is tracked
in this directory.

## Event Types

Ten approved types, closed vocabulary: `observation-received`,
`evidence-created`, `evidence-refreshed`, `verification-created`,
`drift-detected`, `drift-cleared`, `evidence-stale`, `collection-failed`,
`review-required`, `knowledge-state-generated`.

The latest event is **not** the authoritative declared state. The most recent
thing that happened may well be `collection-failed`.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../../docs/decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Knowledge Event Standard](../../docs/standards/knowledge-event-standard.md)
- [Timeline documentation](../../docs/observation/timeline.md)
