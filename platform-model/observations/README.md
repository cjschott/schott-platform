# Observations

This directory holds the **schema-governed definition** of what an observation
is. It does not hold observations.

An observation is the validated, redacted, normalized form of a collector
result, produced before the record is given a persistent identity. It is the
boundary type between collection and evidence — see
[`../schemas/observation.schema.yaml`](../schemas/observation.schema.yaml).

## Nothing generated is committed here

Runtime observations live in an observation store outside the repository, at a
data root supplied explicitly to `tools/observation/cli.py`. They are never
committed, for two reasons.

Generated records would swamp the declared model. A collector on a schedule
produces records continuously, and a repository that mixes thousands of
machine-generated observations with a few dozen human-authored entities stops
being reviewable.

More importantly, the two kinds of record carry different authority. Entities
in `platform-model/` are declared intent: a human wrote them down and another
human reviewed them. Observations are what a machine saw. Storing them in the
same tree invites the assumption that they carry the same weight, and the
whole point of ADR-0004 is that they do not.

`tests/test-knowledge-orchestrator.sh` asserts that no `OBS-` record is
tracked in this directory.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../../docs/decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Observation engine overview](../../docs/observation/overview.md)
- [Evidence store](../../docs/observation/evidence-store.md)
