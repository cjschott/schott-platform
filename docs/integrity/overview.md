# Operational Integrity Engine

Answers one question: **is this still the system we think it is?**

It does not answer it by acting. The engine compares and recommends; a human
decides.

## The pipeline

```
Reality → Observation → Evidence → Verification → Knowledge
        → Snapshot → Digital Twin → Integrity Analysis
        → Recovery Recommendation → Human Approval
```

Everything left of `Snapshot` is the v0.6.0 and v0.7.0 pipeline. This engine
adds the right-hand half, and the chain ends at a person.

## Four concepts

| Concept | What it is | Lifetime |
|---|---|---|
| **Snapshot** | Immutable record of a known-good state | Permanent, never revised |
| **Digital Twin** | Reconstruction of current state from knowledge | Disposable, rebuilt on demand |
| **Integrity Report** | Comparison of twin against snapshot | Optional to persist |
| **Recovery Plan** | Advisory reconstruction strategy | Optional to persist |

### Snapshots never change

A snapshot is written once. A newer snapshot of the same target is a *new*
record; the older one stays readable, because a reference point that can change
after something cited it is not a reference point.

Snapshots are deterministic and fingerprinted: the same knowledge reproduces a
byte-identical record. That is what makes one verifiable rather than merely
stored.

A snapshot records what was **observed** at a moment a human labelled good. It
is not a statement of what the platform *should* be — that distinction keeps it
evidence rather than intent.

### Twins are always disposable

A twin is rebuilt entirely from knowledge, every time. It is never edited
directly: the type is frozen and its facts are write-protected, so a hand-edit
fails rather than silently succeeding.

Disposability is the design. If a twin is always rebuilt from immutable inputs,
a reconstruction bug is a bug in code that a rerun fixes, rather than corrupted
state somebody has to repair by hand.

Twins are returned, not stored. A persisted twin is indistinguishable from a
snapshot at a glance, and the difference between "confirmed good" and
"reconstructed just now" is the entire point.

## The five integrity states

| Status | Meaning |
|---|---|
| `MATCH` | Every comparable fact agrees |
| `PARTIAL` | Some facts agree, some differ |
| `DRIFT` | Every comparable fact differs |
| `UNKNOWN` | Nothing could be compared — snapshot and twin describe different facts |
| `INSUFFICIENT_EVIDENCE` | The twin holds no facts at all |

The last two matter most. Reporting "we could not tell" as `DRIFT` produces a
false alarm on every gap in coverage, and an operator paged three times for a
coverage gap stops reading drift reports — which costs more than the alarm was
ever worth.

**A fact the snapshot never captured is `UNKNOWN`, not drift. A twin with no
facts is `INSUFFICIENT_EVIDENCE`, not drift.**

## Confidence explains itself

Every report carries five factors, their weights, each contribution, and a
written reason per factor:

| Factor | Weight | Measures |
|---|---|---|
| `coverage` | 0.30 | How much of the snapshot could actually be compared |
| `knowledge_freshness` | 0.25 | How current the knowledge behind the twin is |
| `knowledge_confidence` | 0.25 | What the observation layer reported |
| `snapshot_integrity` | 0.10 | Whether the snapshot is a usable reference |
| `determinacy` | 0.10 | Whether the comparison reached a determinate answer |

Weights total exactly `1.0`. Out-of-range or missing factors raise rather than
being clamped or defaulted — a clamped value hides the bug that produced it, and
a defaulted factor changes the score without appearing in the explanation.

**Confidence is an engineering heuristic, not a probability.** A comparison of
two facts out of fifty scores low `coverage` precisely so a narrow conclusion
cannot look like a broad one.

## Recovery is advisory. Always.

A recovery plan is prose. There is no command field, no script, no ordering
primitive an executor could consume, and no `execute` method anywhere in the
package.

That is the decision, not a gap to close later. **Detected drift is frequently
intended change** — someone deployed something — and an engine that reverts a
deployment it did not recognise has caused the incident it was meant to prevent.

Plans therefore say so explicitly. The first step asks whether the snapshot is
still an appropriate reference; the second asks whether each difference was
intended; the last directs any agreed reconstruction through the platform's
normal change process, with its usual review and rollback.

## Usage

Both roots are explicit and never defaulted — a default eventually becomes a
production path someone wrote to by accident.

```bash
# Record a known-good state
python3 -m tools.integrity.cli snapshot \
  --target REPO-0001 --label "known-good after v0.7.0" \
  --evidence-root /srv/schott-platform/observations \
  --store-root /srv/schott-platform/integrity

# Rebuild the current twin (prints it; stores nothing)
python3 -m tools.integrity.cli twin \
  --target REPO-0001 \
  --evidence-root /srv/schott-platform/observations \
  --store-root /srv/schott-platform/integrity

# Compare, and produce an advisory plan
python3 -m tools.integrity.cli analyze --target REPO-0001 ...
python3 -m tools.integrity.cli plan --target REPO-0001 ...
```

There is no `execute`, `recover`, `apply`, or `delete` command.

## What this engine will not do

- execute a recovery, at any severity, under any configuration
- modify `platform-model/` or any declared entity
- contact a remote host, use SSH, or open a socket
- run a subprocess or inspect Docker runtime state
- read `ai/.env` or any secret
- revise a snapshot, or delete one

## Limitations

- **Snapshots decay.** As intended change accumulates a snapshot produces noisy
  `PARTIAL` reports. The engine cannot decide when a state is good; someone must
  take new snapshots.
- **Storage grows monotonically.** Retention is deliberately deferred, as it is
  for evidence.
- **Coverage is only as broad as collection.** The engine compares what was
  observed; facts nothing collects are invisible to it.
- **The engine cannot distinguish intended from unintended change.** That is
  precisely why it does not act.

## Related

- [ADR-0007: Operational Integrity Engine](../decisions/ADR-0007-operational-integrity-engine.md)
- [ADR-0004: Immutable Knowledge Timeline](../decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Observation engine overview](../observation/overview.md)
