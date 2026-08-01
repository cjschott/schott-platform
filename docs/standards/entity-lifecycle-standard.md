# Entity Lifecycle Standard

## Purpose

This standard defines entity **maturity**: how far a platform-model record has progressed from someone's intent toward something automation is trusted to own.

It exists because four different questions are routinely collapsed into one word, and collapsing them is how a model starts lying. A record can be mature and broken. It can be freshly declared and working perfectly. Maturity and health are independent, and this standard keeps them apart.

## Scope

Applies to every entity under `platform-model/`: roles, hosts, services, networks, storage, backup policies, evidence, verifications, and drift rules.

It does not define provenance, verification outcomes, or runtime health.

## The Four Concepts

| Concept | Question | Where it lives | Example values |
|---|---|---|---|
| `lifecycle` | How mature is this record? | Entity field | `declared`, `verified`, `managed` |
| `provenance` | Where did this fact come from? | `provenance.class` | `declared`, `observed`, `inferred` |
| `verification_state` | Did evidence support the declaration? | Verification records | `pending`, `verified`, `drift` |
| `operational_health` | Is it working right now? | **Not modeled** | — |

These are orthogonal. A `managed` host can be down. A `draft` service can be running fine. A `verified` entity is one whose declared facts were supported by evidence **at a point in time**, which says nothing about the present moment.

`operational_health` is deliberately absent from the platform model. Answering it requires live telemetry the platform does not yet have, and a field that looks authoritative but is never refreshed is worse than no field at all.

### Why `observed` is not a lifecycle state

`observed` describes where a fact came from. It is provenance, not maturity.

Using it as a lifecycle state would let a single observation appear to advance an entity's maturity, which inverts the relationship: evidence supports a maturity claim, it does not constitute one. The vocabularies stay separate, and validation enforces it.

## Lifecycle States

- `draft` — Proposed or under construction. Not yet an assertion about the platform.
- `declared` — Recorded as intended state and reviewed through normal change control. Nothing has checked it against reality.
- `verification-pending` — Selected for verification; evidence has been requested or is being collected.
- `verified` — Sufficient evidence supported the declared identity and required facts at a point in time.
- `managed` — Approved automation owns at least part of this entity's lifecycle.
- `deprecated` — Scheduled for removal. Still resolvable, still referenced by history.
- `archived` — Retired. Retained for historical reference only.

## Transitions

```text
draft -> declared -> verification-pending -> verified -> managed -> deprecated -> archived
```

One regression is permitted:

```text
verified -> verification-pending
```

This applies when evidence becomes stale or contradictory. It is a regression, not a failure: it records that the platform no longer knows, which is the honest state when supporting evidence has expired.

### Transition requirements

Every transition must record:

- `reason` — why the entity moved
- `actor` — who or what moved it
- `timestamp` — RFC 3339 with an explicit offset

A transition without these is invalid. An unexplained maturity change is indistinguishable from a mistake.

### Constraints

- **Archived identifiers must never be reused.** History that points at a reused id becomes silently wrong.
- **Deprecated entities remain resolvable.** References from historical records must continue to work.
- **Lifecycle does not imply runtime health.** No consumer may read `verified` or `managed` as "currently working".
- **Runtime drift does not automatically rewrite lifecycle.** A drift finding is a signal for review, not a state machine trigger. Automation that demotes entities on drift would let a single failed collection rewrite the model's maturity.
- **Automation must not promote an entity to `verified` without evidence references.** Promotion requires at least one resolvable evidence id.
- **High-impact transitions require explicit approval.** Promotion to `managed` and any move to `deprecated` or `archived` change what automation is permitted to touch and what operators can still find.

## What `verified` Does and Does Not Mean

**Means:** at the recorded evaluation time, evidence existed that supported the entity's declared identity and its required facts.

**Does not mean:** the entity is healthy, reachable, correctly configured in every respect, or still in that state now.

Verification has a timestamp for the same reason evidence does. The further from that timestamp a consumer is, the weaker the claim, and consumers must qualify it by age rather than presenting it as current.

## What `managed` Means

Approved automation owns at least part of this entity's lifecycle — provisioning, configuration, or recovery.

Promotion to `managed` is a statement that changes should flow through automation rather than by hand. It raises the cost of undocumented manual change, which is the point, and is why it requires explicit approval.

## Relationship to Verification

Verification records never rewrite entity lifecycle automatically. They produce findings; a human or an approved process decides whether a finding justifies a transition.

This separation exists so a transient collection failure cannot cascade into a model-wide maturity downgrade.

## Compliance

An entity complies with this standard when:

- It carries a lifecycle value from the approved vocabulary.
- Its lifecycle is distinct from its provenance class.
- Transitions record reason, actor, and timestamp.
- Promotion to `verified` references supporting evidence.
- Archived identifiers are not reused.
- Deprecated entities remain resolvable.
- No consumer presents lifecycle as a statement of runtime health.
