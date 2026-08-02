# State Transitions at Runtime

The transition table is **code-owned and explicit**. Every permitted change is
written out in `tools/trust/transitions.py`, so "can this become trusted?" is
answered by reading a table rather than tracing conditionals.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md). See also
[trust states](trust-states.md).

## Two rules govern the whole table

1. **Only `Expired` may occur automatically**, through the passage of time from
   a usable state.
2. **No automatic transition may produce a usable or judgemental state.**
   Nothing becomes trusted, restricted, quarantined, revoked, or rejected
   because time passed or a condition cleared.

## Permitted by decision

| From | May become |
|---|---|
| `Unknown` | `Pending`, `Trusted`, `Restricted`, `Quarantined`, `Rejected` |
| `Pending` | `Trusted`, `Restricted`, `Quarantined`, `Rejected` |
| `Trusted` | `Restricted`, `Quarantined`, `Revoked` |
| `Restricted` | `Trusted`, `Quarantined`, `Revoked` |
| `Quarantined` | `Trusted`, `Restricted`, `Revoked`, `Rejected` |
| `Expired` | `Trusted`, `Restricted` — renewal, **same lineage** |
| `Revoked` | nothing — terminal within its lineage |
| `Rejected` | nothing — terminal within its lineage |

## Permitted by time

| From | May become | Rule |
|---|---|---|
| `Trusted` | `Expired` | the grant elapsed past its recorded expiration |
| `Restricted` | `Expired` | the bounded grant elapsed past its expiration |

Nothing else. An automatic transition to any other state is refused with the
governing rule as its reason.

## Expiry continues the lineage

ADR-0011 said an expired subject "requires a new decision, not an automatic
extension" but did not say whether that decision continues the lineage or
starts a new one. **Resolved: it continues the same lineage.**

Expiry means the grant aged out, not that anything went wrong. Forcing a new
lineage would fragment a periodically-renewed subject's history into one chain
per renewal, and the whole point of a lineage is that a subject's history reads
in order.

```
LINEAGE TLIN-000001  (host schmgmt.home.arpa)
  TDEC-000001  unknown -> trusted    renewal boundary recorded
  (time)       trusted -> expired    effective only; nothing written
  TDEC-000002  expired -> trusted    renewal, same lineage
```

`Revoked` and `Rejected` remain terminal: later approval requires a **new
lineage**, supplied explicitly, which references the prior history without
mutating it.

## Every outcome explains itself

A transition result carries the previous state, the requested state, whether it
was allowed, the governing rule, whether a decision is required, whether a new
lineage is required, and whether the result would be usable.

An operator seeing "denied" during an incident needs the rule and what to do
instead — not a boolean.

Unrecognised states fail closed rather than falling through to a default.

## Related

- [Trust Plane runtime overview](runtime-overview.md)
- [Trust states](trust-states.md)
