# Evidence Records

Immutable, timestamped support for observed facts about platform entities.

**This directory is empty of records, and that is correct.** A record appears here only when a real observation or provisioning ceremony produces one; fabricating one to fill the directory would defeat the entire purpose of an evidence layer.

## Declarative evidence is not the runtime evidence store

Two planes, deliberately separate:

| | `platform-model/evidence/` | `tools/observation` EvidenceStore |
|---|---|---|
| Nature | Declarative, reviewed, Git-governed | Dynamic observation history |
| Lives | In this repository | Outside any repository — it refuses a root inside one |
| Identifiers | Lowest unused `EVID-NNNNNN`, derived from what is here | Allocated from a locked sequence file |
| Purpose | Supports platform-model and governance decisions | Records what collectors saw, over time |

Neither allocates for the other. Pointing the runtime store at this directory is not supported, and its refusal to sit inside a repository is a safety rule rather than an inconvenience.

## Content fingerprint

`content_fingerprint` is recomputed and enforced by `tools/platform_model/validate_evidence.py`; a record whose digest disagrees with its content is refused.

The digest is `sha256:` followed by 64 lowercase hexadecimal characters, taken over the **semantic claim** and nothing else. The preimage is exactly six fields:

| Preimage key | Taken from | Why it participates |
|---|---|---|
| `schema_version` | the record's `api_version` | binds the interpretation of the payload |
| `target` | `target` | identical facts about two hosts are not the same evidence |
| `source_type` | `source_type` | command output and a human attestation are different authorities |
| `collector` | `collector` | who observed it is part of the claim |
| `status` | `status` | a failed collection must not match a successful one |
| `facts` | `facts` | the normalized source material |

Excluded, so that re-observing an unchanged machine reproduces the same digest: `id`, `collected_at`, `provenance`, `retention`, `references`, `sensitivity`, and `content_fingerprint` itself.

Canonicalisation, precisely enough to reimplement:

```python
json.dumps(preimage, sort_keys=True, separators=(",", ":"),
           ensure_ascii=False).encode("utf-8")
```

SHA-256 over exactly those bytes, rendered lowercase with the `sha256:` prefix. No `default=` coercion: a value JSON cannot represent refuses rather than being stringified. YAML key order, indentation, and quoting style therefore cannot affect the digest. The one implementation is `tools/platform_model/evidence_fingerprint.py`, consumed by both the generator and the validator.

## Purpose

An evidence record makes exactly one kind of claim:

> At `collected_at`, this collector observed these facts about this target.

It never claims those facts are still true. The schema gives it no way to.

## File Naming

```text
evid-000001-<short-slug>.yaml
```

One record per file. Filenames include the id because evidence is immutable and append-only — unlike entities, an evidence record is never renamed or renumbered.

## Stable IDs

`EVID-000001`, six digits, never reused. Recollection creates a **new** id; it does not overwrite the old record. Two collections are two facts about two moments.

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
id: EVID-000001
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
content_fingerprint: sha256:<64 lowercase hex over the semantic preimage>
redaction:
  performed: false
facts:
  hostname: schai
  secret_present: true
  secret_source: ai/.env
references: []
```

## Ceremonies

The first ceremony is the schai host-architecture observation:

```bash
python3 tools/platform_model/observe_host_architecture.py
```

It reads `uname -m`, `lscpu`, and `dpkg --print-architecture`, requires all three to agree after normalisation through the governed Fabric host rule, and prints a candidate record. **It writes nothing without `--publish-to`.** No record has been published yet.

## What Does Not Exist Yet

- No automatic runtime collection into this directory.
- No automatic remediation, at any severity, under any configuration.
