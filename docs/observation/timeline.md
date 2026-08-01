# Knowledge Timeline

The timeline answers a question a store of facts cannot: *when did we learn
this, and what has happened since?*

## Append-only by construction

Events are written through the evidence store, which refuses to overwrite an
existing record. Append-only is therefore a property of the storage layer, not
of the timeline module behaving well — there is no rewrite path here because
there is none underneath.

A mistaken event is corrected by appending a later one. The original stays,
because the fact that the platform once believed something is itself part of
the record.

## Ordering

Sorted by `occurred_at`, then by identifier.

The identifier tiebreak is not cosmetic. Several events are commonly written
during one ingestion and share a timestamp; without a deterministic secondary
sort, the timeline reorders between runs and no two queries agree. With it,
repeated queries are byte-identical.

## The latest event is not the current state

This is the most important thing to understand about a timeline.

The most recent event may be `collection-failed`. Reading it as current state
would report a target as broken when the only thing that broke was the
collector. A timeline records *what happened*; current belief is derived
separately, from evidence, by [knowledge state](knowledge-state.md).

Treating the newest event as truth reintroduces exactly the mutable
current-state failure mode ADR-0004 rejects.

## Event types

Ten, closed vocabulary — see the
[Knowledge Event Standard](../standards/knowledge-event-standard.md):

`observation-received`, `evidence-created`, `evidence-refreshed`,
`verification-created`, `drift-detected`, `drift-cleared`, `evidence-stale`,
`collection-failed`, `review-required`, `knowledge-state-generated`.

An unapproved type is rejected rather than recorded. An open-ended vocabulary
forces every consumer to handle types it has never seen, and consumers handle
the unknown by ignoring it.

## Refresh versus creation

A duplicate observation produces `evidence-refreshed` and **no new evidence
record**.

This is what keeps a five-minute collection schedule from producing hundreds
of identical records a day. The knowledge that a fact was reconfirmed is
preserved as an event; the fact itself is not duplicated. Freshness improves,
storage does not grow, and the signal stays readable.

## Querying

```bash
python3 -m tools.observation.cli timeline \
  --target REPO-0001 \
  --store-root /srv/schott-platform/observations-test
```

Returns JSON on stdout, ordered as above. Every event names the evidence or
verification that caused it, so any entry can be traced back to the record it
came from.

## Related

- [Knowledge Event Standard](../standards/knowledge-event-standard.md)
- [Evidence store](evidence-store.md)
- [Knowledge state](knowledge-state.md)
