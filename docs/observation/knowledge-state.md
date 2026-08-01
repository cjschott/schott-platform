# Knowledge State

What the platform currently believes about one target, derived on demand.

## Derived, never stored as truth

Knowledge state is computed from immutable evidence, verifications, and events
every time it is asked for. It is never persisted as authoritative.

This is the central design choice. If the current answer is always derived,
then a bug in derivation is a bug in code that a rerun fixes — not corrupted
data that has to be found and repaired by hand. The inputs cannot rot, because
the inputs are immutable.

It may be cached under `state/` in a store root. That cache is disposable, is
excluded from source control, and is never read as a source of truth.

## Determinism

The same inputs always produce byte-identical output. Two rebuilds of the same
target at the same `generated_at` are indistinguishable.

That is what makes the state safe to cache and safe to discard, and it is
asserted in the test suite by rebuilding twice and comparing serialized output.

## What it reports

| Field | Meaning |
|---|---|
| `newest_evidence_at` | Collection time of the most recent supporting evidence |
| `knowledge_age_seconds` | Elapsed time from that evidence to `generated_at` |
| `freshness` | `current`, `aging`, `stale`, or `unknown` |
| `confidence` | Score plus every factor, weight, and contribution |
| `supporting_evidence` | The `EVID` identifiers behind the conclusion |
| `verification_state` | State of the most recent verification |
| `drift_results` | Outstanding differences, advisory only |
| `conflicts` | Facts where independent collectors disagree |
| `latest_events` | Recent timeline entries for context |
| `review_required` | Whether a human needs to look |

## Declared, observed, and inferred stay separate

`provenance_classes` reports all three independently.

Merging them would let observation masquerade as reviewed intent, which is the
failure ADR-0004 exists to prevent. A knowledge state can say "declared says
`main`, observed says `hotfix`, and I infer these disagree" — it can never say
"the branch is `hotfix`" as though that were intent.

Nothing here writes back to a declared entity. Promoting an observation to
declared intent is a human decision.

## Conflict detection

A conflict requires **independent collectors** reporting different values for
the same fact.

The same collector reporting a different value later is change over time, not
disagreement — flagging that would mark every legitimate update as a conflict
and make the field useless.

A conflict lowers `source_agreement` sharply and sets `review_required`. It is
never reported as drift: the platform does not know which source is right, and
claiming otherwise would be a guess dressed as a finding.

## When review is required

`review_required` is true when any of these hold:

- independent collectors conflict
- outstanding drift or a collection failure exists
- freshness is `unknown` or `stale`
- no usable evidence exists
- the newest verification is `unknown`, `failed`, or `warning`

The bias is deliberate. A false "please look" costs a few seconds; a false
"everything is fine" is exactly the failure an evidence platform exists to
prevent.

## Usage

```bash
python3 -m tools.observation.cli knowledge \
  --target REPO-0001 \
  --store-root /srv/schott-platform/observations-test \
  --declared /approved/input/repo-0001.json \
  --rules /approved/input/rules.json
```

Read-only: it reads records and returns a value.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Confidence and freshness](confidence-and-freshness.md)
- [Timeline](timeline.md)
- [Evidence store](evidence-store.md)
