# Observation Engine Overview

The observation engine turns what collectors saw into what the platform
remembers. It is the layer between collection and knowledge, and it exists
because those two things need different trust levels.

## The pipeline

```
CollectorResult  →  Observation  →  Immutable Evidence  →  Verification
                                                              ↓
        Derived Knowledge State  ←  Knowledge Event  ←  Drift Assessment
```

Each stage has one job:

| Stage | Responsibility |
|---|---|
| `CollectorResult` | What a plugin returns. No identifier, no store access. |
| `Observation` | The result validated, redacted, normalized, fingerprinted. |
| `Evidence` | An observation given a persistent identifier and written once. |
| `Verification` | Declared intent compared against evidence. |
| `Drift Assessment` | The difference classified, never acted on. |
| `Knowledge Event` | A durable record that something happened. |
| `Knowledge State` | Derived on demand; never stored as truth. |

## Why collectors do not persist

A collector that numbers and stores its own records controls the audit trail.
Every guarantee about evidence would then be only as strong as the least
careful plugin, and a bug in one collector could rewrite history for all of
them.

Keeping allocation and persistence in one place means the rules are enforced
once, in code that is reviewed as a unit. The orchestrator, in turn, never
executes a collector — it consumes results and never produces them — so the
memory layer does not inherit the blast radius of every plugin.

## Modules

| Module | Role |
|---|---|
| `models.py` | Frozen dataclasses; no field can hold a command. |
| `evidence_builder.py` | `CollectorResult` → `Observation` → `EvidenceRecord`. |
| `deduplicator.py` | Decides whether an observation is genuinely new. |
| `evidence_store.py` | Atomic, overwrite-refusing, append-only storage. |
| `confidence.py` | Explainable scoring and freshness assessment. |
| `verifier.py` | Compares declared intent against evidence. |
| `drift_engine.py` | Classifies differences; recommends only in prose. |
| `timeline.py` | Append-only event log with deterministic ordering. |
| `knowledge.py` | Derives current state from immutable inputs. |
| `orchestrator.py` | The thirteen-step lifecycle. |
| `cli.py` | `ingest`, `timeline`, `knowledge`, `verify`, `validate-store`. |

## What this layer cannot do

By construction, not by policy:

- **No network.** Nothing in the package imports a socket, HTTP, or SSH module.
- **No subprocess.** Nothing executes a command.
- **No Docker runtime.** Nothing inspects a container.
- **No model mutation.** Nothing writes into `platform-model/`.
- **No deletion or update.** The store has no such method.
- **No remediation.** No function acts on a finding.

`tests/test-knowledge-orchestrator.sh` asserts each of these behaviourally and
backs them with static greps.

## Usage

Every path is explicit. There is no default store root, because a default
eventually becomes a production path someone wrote to by accident.

```bash
python3 -m tools.observation.cli ingest \
  --collector-result result.json \
  --input-dir /approved/input \
  --store-root /srv/schott-platform/observations-test

python3 -m tools.observation.cli knowledge \
  --target REPO-0001 \
  --store-root /srv/schott-platform/observations-test
```

## Limitations

- **Local and single-host.** Sequence allocation is safe for one host; multi-host collection would need a different mechanism.
- **Confidence is a heuristic.** Explainable and deterministic, but not statistically calibrated.
- **Storage grows monotonically.** Retention is deliberately not decided yet.
- **Derivation cost scales with history.** Every knowledge query reads the target's records.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Evidence store](evidence-store.md)
- [Timeline](timeline.md)
- [Confidence and freshness](confidence-and-freshness.md)
- [Knowledge state](knowledge-state.md)
