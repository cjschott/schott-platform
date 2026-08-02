# Trust Query Reference

Read-only. **Nothing here writes, allocates an identifier, or emits an audit
event.** Asking what is trusted must not change what is trusted, and an audit
trail that records questions as well as changes buries the changes.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md).

## Commands

```bash
# Current stored and effective state for a subject.
python3 -m tools.trust.cli show-subject \
    --store-root /var/lib/kyri/trust \
    --subject-id HOST-0001 \
    --evaluated-at 2026-08-02T09:00:00-05:00

# Full evaluation: activity plus scope, with every denial explained.
python3 -m tools.trust.cli evaluate \
    --store-root /var/lib/kyri/trust \
    --subject-id HOST-0001 \
    --activity-kind normal \
    --capability coding-workload \
    --operation linux.hostname \
    --data-classification internal \
    --target schmgmt.home.arpa \
    --evaluated-at 2026-08-02T09:00:00-05:00

# Every decision affecting a subject, oldest first.
python3 -m tools.trust.cli list-history \
    --store-root /var/lib/kyri/trust --subject-id HOST-0001

# The newest version of one lineage.
python3 -m tools.trust.cli show-lineage \
    --store-root /var/lib/kyri/trust --lineage-id TLIN-000001

# Structural problems. Reports; repairs nothing.
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
```

`--evaluated-at` is required wherever time matters. Output is deterministic
JSON on stdout; diagnostics go to stderr.

## What every answer contains

- **stored_state** and **effective_state**, separately
- **usable** — whether the subject may be used at all
- **allowed** and **denied_reasons** — every reason, in full
- **lineage_id**, **record_id**, **decision_id** — the references to follow
- **evaluated_at** — the moment the answer describes

## Deny-by-default, on every dimension

A request that does not name a capability, an operation, a data classification,
and a target is **denied** — not because the scope forbade it, but because
nothing permitted it. An unstated dimension is the most common way a bounded
grant quietly becomes an unbounded one.

## State overrides scope

A quarantined, revoked, expired, rejected, unknown, or pending subject is denied
**even when its recorded scope matches the request perfectly**. The scope
describes what a grant would permit; the state describes whether there is a
grant.

When state denies, the scope reasons are suppressed — listing them would suggest
a different scope could have helped.

## Fails closed, three distinct ways

Each with its own written reason, and all evaluating to `unknown`:

- no trust lineage exists for the subject
- the lineage head cites a decision with no trust record
- the trust record cannot be interpreted

A missing subject is not an error to swallow. It is an answer.

## Determinism

History is ordered by decision time then identifier, so repeated calls return
the same sequence and two decisions sharing a timestamp still order
deterministically.

## No interpretation

There is no natural-language interpretation of trust state and no model
involved. **Reasoning may consume trust; trust never consumes reasoning.**

## Related

- [Trust Plane runtime overview](runtime-overview.md)
- [State transitions at runtime](state-transition-runtime.md)
