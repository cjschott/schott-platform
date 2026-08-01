# Evidence Records

Immutable, timestamped support for observed facts about platform entities.

**This directory is empty of records, and that is correct.** No collector exists yet. Sprint 4 built the schema and validation foundation; fabricating an evidence record to fill the directory would defeat the entire purpose of an evidence layer.

## Purpose

An evidence record makes exactly one kind of claim:

> At `collected_at`, this collector observed these facts about this target.

It never claims those facts are still true. The schema gives it no way to.

## File Naming

```text
evid-0001-<short-slug>.yaml
```

One record per file. Filenames include the id because evidence is immutable and append-only — unlike entities, an evidence record is never renamed or renumbered.

## Stable IDs

`EVID-0001`, four digits, never reused. Recollection creates a **new** id; it does not overwrite the old record. Two collections are two facts about two moments.

## Declared vs Observed vs Inferred

| Class | Meaning | Used here |
|---|---|---|
| `declared` | Written into the model as intent | Entities, not evidence |
| `observed` | Collected from a live system at a moment | **Always, for evidence** |
| `inferred` | Derived by a rule | Verification results |

Evidence provenance is always `observed` and always carries `observed_at`.

## Lifecycle vs Verification State

Evidence has no verification state — it *is* what verification consumes. Its lifecycle vocabulary is limited to `declared`, `deprecated`, and `archived`, because there is no meaningful "verified evidence".

## Immutability

- Existing records are never edited. A record describes one moment; editing it destroys the only thing it was for.
- Corrections **supersede** via `SUPERSEDES`, and both records remain.
- Raw command output is not committed. Records carry normalized facts plus a `content_fingerprint`, which proves what was seen without republishing it.

## Redaction

Every record declares whether redaction was performed. Evidence may record secret *metadata*:

```yaml
facts:
  secret_present: true
  secret_source: ai/.env
```

It must never record a secret value. Validation rejects secret-bearing keys and reports them by key path with the value withheld.

## Validation

```bash
python3 tools/platform_model/validate_evidence.py --root platform-model
```

## Example

Synthetic, non-secret:

```yaml
id: EVID-0001
type: evidence
target: HOST-0001
source_type: manual-attestation
collector: operator-review
collected_at: 2026-08-01T09:00:00-05:00
status: success
provenance:
  class: observed
  observed_at: 2026-08-01T09:00:00-05:00
sensitivity: internal
retention: 90d
content_fingerprint: sha256:<digest of normalized source material>
redaction:
  performed: false
facts:
  hostname: schai
  secret_present: true
  secret_source: ai/.env
references: []
```

## What Does Not Exist Yet

- No runtime collection. Nothing contacts a host.
- No automatic remediation, at any severity, under any configuration.
